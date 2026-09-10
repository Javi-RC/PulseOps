defmodule PulseOps.Monitoring.Service do
  @moduledoc """
  A monitored endpoint. Each enabled service is watched by its own supervised
  process, which probes `url` every `check_interval_ms`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PulseOps.Monitoring.UrlGuard
  alias PulseOps.Organizations.Organization
  alias PulseOps.Vault.EncryptedMap

  @environments [:production, :staging, :development]
  @statuses [:unknown, :healthy, :degraded, :down]

  # GET and HEAD cover almost every health endpoint; POST is there for the ones
  # that want a payload. Nothing that changes state on the far side belongs on a
  # schedule, so PUT, PATCH and DELETE are deliberately absent.
  @http_methods [:get, :head, :post]

  # Enough to carry an Authorization header and a couple of others, not enough
  # to be used as free storage.
  @max_headers 10
  @max_header_length 200
  @max_body_length 4_000

  # A check that fires faster than every 10s is a load test, not monitoring; an
  # interval beyond an hour stops being useful for incident detection.
  @min_interval_ms 10_000
  @max_interval_ms 3_600_000
  @min_timeout_ms 1_000
  @max_timeout_ms 30_000

  @type t :: %__MODULE__{}

  schema "services" do
    field :name, :string
    field :description, :string
    field :environment, Ecto.Enum, values: @environments, default: :production
    field :url, :string
    field :check_interval_ms, :integer, default: 60_000
    field :timeout_ms, :integer, default: 5_000
    field :enabled, :boolean, default: true
    field :public, :boolean, default: true
    field :http_method, Ecto.Enum, values: @http_methods, default: :get
    # Often an Authorization header, so encrypted at rest and redacted like a
    # webhook's token (ADR-018).
    field :request_headers, EncryptedMap, default: %{}, redact: true
    field :request_body, :string
    field :expected_status, :integer
    field :body_assertion, :string
    field :status, Ecto.Enum, values: @statuses, default: :unknown
    field :last_checked_at, :utc_datetime
    field :tls_expires_at, :utc_datetime
    field :tls_checked_at, :utc_datetime
    field :tls_error, :string
    field :tls_warned_for, :utc_datetime

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  def environments, do: @environments
  def statuses, do: @statuses
  def http_methods, do: @http_methods

  @doc """
  Changeset for user-supplied service attributes.

  `status` and `last_checked_at` are deliberately not castable here: they are
  owned by the monitor process, not by the form.
  """
  def changeset(service, attrs, organization_scope) do
    service
    |> cast(attrs, [
      :name,
      :description,
      :environment,
      :url,
      :check_interval_ms,
      :timeout_ms,
      :enabled,
      :public,
      :http_method,
      :request_headers,
      :request_body,
      :expected_status,
      :body_assertion
    ])
    |> validate_required([:name, :environment, :url, :check_interval_ms, :timeout_ms])
    |> validate_length(:name, min: 2, max: 80)
    |> validate_url(:url)
    |> validate_inclusion(:http_method, @http_methods)
    |> validate_number(:expected_status,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 599
    )
    |> validate_length(:body_assertion, min: 1, max: 200)
    |> validate_length(:request_body, max: @max_body_length)
    |> validate_request_headers()
    |> validate_body_assertion_needs_a_body()
    |> validate_number(:check_interval_ms,
      greater_than_or_equal_to: @min_interval_ms,
      less_than_or_equal_to: @max_interval_ms
    )
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: @min_timeout_ms,
      less_than_or_equal_to: @max_timeout_ms
    )
    |> validate_timeout_fits_interval()
    |> put_change(:organization_id, organization_scope.organization.id)
    # Reported against :name rather than the composite default, so the form shows
    # the error under the field the user can actually change.
    |> unique_constraint(:name,
      name: :services_organization_id_name_index,
      message: "a service with this name already exists"
    )
    |> foreign_key_constraint(:organization_id)
  end

  @doc """
  Changeset used by the monitor to record the outcome of a check.

  Kept separate from `changeset/3` so that a probe result can never be smuggled
  in through a user-facing form, and vice versa.
  """
  def status_changeset(service, attrs) do
    service
    |> cast(attrs, [:status, :last_checked_at])
    |> validate_required([:status])
  end

  # UrlGuard covers the scheme check and, unless private targets are allowed,
  # rejects anything resolving into the network PulseOps runs in. The same guard
  # runs again just before each probe, because a name can be repointed between
  # saving and fetching.
  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case UrlGuard.validate(value) do
        :ok -> []
        {:error, reason} -> [{field, UrlGuard.message(reason)}]
      end
    end)
  end

  # Headers come from a form as a map of strings. A newline in either half is
  # header injection — it lets a tenant append headers of their own to a request
  # PulseOps makes on their behalf — so it is rejected here rather than left to
  # whatever the HTTP client happens to do with it.
  defp validate_request_headers(changeset) do
    case get_field(changeset, :request_headers) do
      headers when headers in [nil, %{}] ->
        changeset

      headers when is_map(headers) ->
        headers
        |> Enum.reject(fn {name, value} -> blank?(name) and blank?(value) end)
        |> Map.new()
        |> check_headers(changeset)

      _other ->
        add_error(changeset, :request_headers, "must be a set of name and value pairs")
    end
  end

  defp check_headers(headers, changeset) do
    cond do
      map_size(headers) > @max_headers ->
        add_error(changeset, :request_headers, "cannot have more than #{@max_headers} headers")

      Enum.any?(headers, fn {name, _value} -> blank?(name) end) ->
        add_error(changeset, :request_headers, "every header needs a name")

      Enum.any?(headers, &oversized_header?/1) ->
        add_error(
          changeset,
          :request_headers,
          "a header name and value must each be under #{@max_header_length} characters"
        )

      Enum.any?(headers, &unsafe_header?/1) ->
        add_error(changeset, :request_headers, "a header cannot contain a line break")

      Enum.any?(headers, fn {_name, value} -> not printable_ascii?(value) end) ->
        add_error(
          changeset,
          :request_headers,
          "a header value may only contain printable ASCII characters"
        )

      Enum.any?(headers, fn {name, _value} -> not valid_header_name?(name) end) ->
        add_error(
          changeset,
          :request_headers,
          "a header name may only contain letters, digits and -_.~+"
        )

      true ->
        put_change(changeset, :request_headers, headers)
    end
  end

  defp oversized_header?({name, value}) do
    String.length(to_string(name)) > @max_header_length or
      String.length(to_string(value)) > @max_header_length
  end

  defp unsafe_header?({name, value}) do
    String.contains?(to_string(name), ["\r", "\n"]) or
      String.contains?(to_string(value), ["\r", "\n"])
  end

  # RFC 9110 field values are visible ASCII, spaces and tabs. Anything else would
  # be mangled or refused by the far side — and the service form's mask for a
  # hidden value is not ASCII, so it can never be sent as if it were one.
  defp printable_ascii?(value), do: Regex.match?(~r/^[\x20-\x7E\t]*$/, to_string(value))

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  # An RFC 9110 field name is a token. Checking it here is what turns a line the
  # form could not parse into "that is not a header name" rather than a request
  # that fails somewhere inside the HTTP client.
  defp valid_header_name?(name) do
    Regex.match?(~r/^[A-Za-z0-9!#$%&'*+.^_`|~-]+$/, to_string(name))
  end

  # HEAD responses have no body by definition, so asserting on one would fail
  # every probe for a reason the form can explain now instead.
  defp validate_body_assertion_needs_a_body(changeset) do
    assertion = get_field(changeset, :body_assertion)
    method = get_field(changeset, :http_method)

    if method == :head and not blank?(assertion) do
      add_error(
        changeset,
        :body_assertion,
        "cannot be checked on a HEAD request, which has no body"
      )
    else
      changeset
    end
  end

  # A request still in flight when the next one is due would overlap with it and
  # make the failure counters meaningless.
  defp validate_timeout_fits_interval(changeset) do
    interval = get_field(changeset, :check_interval_ms)
    timeout = get_field(changeset, :timeout_ms)

    if is_integer(interval) and is_integer(timeout) and timeout >= interval do
      add_error(changeset, :timeout_ms, "must be shorter than the check interval")
    else
      changeset
    end
  end
end
