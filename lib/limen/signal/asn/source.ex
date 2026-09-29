defmodule Limen.Signal.Asn.Source do
  @moduledoc """
  Where `Limen.Signal.Asn` looks client addresses up.

  The default source is `Limen.Signal.Asn` itself, which reads the
  iptoasn.com data `Limen.Signal.Asn.Loader` loads. An application that
  already keeps IP data current, such as MaxMind's GeoLite2 databases, can
  have the signal read that instead:

      defmodule MyApp.GeoAsn do
        @behaviour Limen.Signal.Asn.Source

        @impl true
        def lookup(_instance, ip) do
          case MyApp.GeoIP.lookup(ip) do
            {:ok, %{asn: asn, org: org, country: country}} ->
              %{asn: asn, name: org, country: country}

            :not_found ->
              nil
          end
        end
      end

      config :my_app, Limen, asn: [source: MyApp.GeoAsn]

  `lookup/2` runs on the request path, for every request whose policy uses
  an ASN signal: it must be fast and must not call a process or send a
  message. Read data your application keeps in `:persistent_term` or ETS.

  An entry may leave out any key. Without `:kind`, `Limen.Signal.Asn`
  classifies the `:asn` as it does its own data (see `Limen.Signal.Asn.kind/2`);
  a source that knows better, say from the organisation's name, can set
  `kind: :hosting` or `kind: :other` itself. A lookup that raises counts as
  a miss, and the error is kept as the signal's evidence.
  """

  @typedoc """
  What a source knows about an address. Every key is optional.
  """
  @type entry :: %{
          optional(:asn) => pos_integer() | nil,
          optional(:country) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:kind) => :hosting | :other
        }

  @doc """
  Looks `ip` up for `instance`, returning `nil` for an unknown address.
  """
  @callback lookup(instance :: atom(), ip :: :inet.ip_address()) :: entry() | nil
end
