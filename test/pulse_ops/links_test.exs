defmodule PulseOps.LinksTest do
  use ExUnit.Case, async: true

  alias PulseOps.Incidents.Incident
  alias PulseOps.Links
  alias PulseOps.Organizations.Organization

  test "an incident's link is the configured public URL plus its page" do
    incident = %Incident{id: 42, organization: %Organization{slug: "acme"}}

    assert Links.incident_url(incident) ==
             Application.fetch_env!(:pulse_ops, :public_url) <> "/orgs/acme/incidents/42"
  end

  test "there is no link without the organization it belongs to" do
    assert Links.incident_url(%Incident{id: 42, organization: nil}) == nil
  end
end
