[
  # Ecto.Multi carries a MapSet internally, and MapSet's opaque type makes
  # Dialyzer report an opacity violation on every `Multi.new() |> Multi.insert(...)`
  # chain under OTP 28. Nothing the calling code can do about it:
  #
  #   https://github.com/elixir-ecto/ecto/issues/2693
  #   https://elixirforum.com/t/function-call-without-opaqueness-type-mismatch-under-otp-28/72407
  #
  # Scoped to this one warning type in the two contexts that use Multi, and
  # `list_unused_filters: true` in mix.exs makes the build complain if either
  # entry stops being needed.
  {"lib/pulse_ops/accounts.ex", :call_without_opaque},
  {"lib/pulse_ops/organizations.ex", :call_without_opaque},
  {"lib/pulse_ops/incidents.ex", :call_without_opaque}
]
