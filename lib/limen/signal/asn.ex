defmodule Limen.Signal.Asn do
  @moduledoc """
  Maps the client address to its autonomous system (ASN).

  An [autonomous system][ASN] is a network run by one operator, such as a
  cloud provider, a hosting company or an ISP, and identified on the internet
  by its number.

  Traffic from hosting providers and clouds is far more likely to be
  automated than traffic from residential and mobile networks. This signal
  looks the client address up in an IP-to-ASN table and classifies the ASN.

  ## Data

  The data comes in the format of the [iptoasn.com][iptoasn]
  `ip2asn-combined.tsv` dataset, gzipped or not:

      range_start<TAB>range_end<TAB>asn<TAB>country<TAB>description

  It is packed into a single `:persistent_term` entry (see
  `Limen.Signal.Asn.Table`): the full dataset, about 580,000 routed ranges,
  takes about 10 MB, and a lookup is a few hundred nanoseconds of binary
  matching, without copying the table or taking a lock.

  `Limen.Signal.Asn.Loader` loads it off the request path, from the `:file`
  of the `:asn` configuration, and with a `:url` also keeps it current:

      config :my_app, Limen,
        asn: [
          file: "/var/lib/my_app/ip2asn-combined.tsv.gz",
          url: "https://iptoasn.com/data/ip2asn-combined.tsv.gz",
          refresh: [
            every: :timer.hours(24),
            window: {~T[01:00:00], ~T[05:00:00]},
            max_utilization: 0.8
          ]
        ]

  The file is where downloads are kept, so a node that starts loads the last
  data it had without waiting for the network, and checks for new data on
  schedule: once a day here, at a random time between 01:00 and 05:00 UTC,
  unless its schedulers are busier than 80%. See the `:asn` options of
  `Limen.Config` and `Limen.Signal.Asn.Schedule`.

  iptoasn.com publishes its data in the public domain. Any source in the
  same format works, such as a file your own pipeline writes.

  ## Classification

  `:asn_kind` is `:hosting` for a built-in list of large cloud and hosting
  providers plus any ASN in the `:hosting` option, `:other` for any other
  known ASN and `:unknown` when the address is not in the table (or no table
  is loaded). Google and Microsoft run crawlers from their main ASNs; allow
  verified crawlers before scoring hosting providers.

  Provides `:asn`, `:asn_kind`, `:asn_country` and `:asn_name`.

  [ASN]: https://www.rfc-editor.org/rfc/rfc1930
  [iptoasn]: https://iptoasn.com/
  """

  @behaviour Limen.Signal

  alias Limen.Context
  alias Limen.Signal.Asn.Table

  # Large cloud and hosting providers. Deliberately conservative: an ASN
  # belongs here only when most of its traffic is servers, not people.
  @hosting MapSet.new([
             # Amazon
             16_509,
             14_618,
             8987,
             # Google Cloud
             396_982,
             # Microsoft Azure
             8075,
             # DigitalOcean
             14_061,
             # Hetzner
             24_940,
             213_230,
             # OVH
             16_276,
             # Akamai Connected Cloud (Linode)
             63_949,
             # Vultr
             20_473,
             # Oracle Cloud
             31_898,
             # Alibaba Cloud
             45_102,
             # Tencent Cloud
             132_203,
             # Contabo
             51_167,
             # Scaleway
             12_876,
             # Leaseweb
             60_781,
             # ColoCrossing
             36_352,
             # M247
             9009
           ])

  @type entry :: Table.entry()

  @impl true
  def provides, do: [:asn, :asn_kind, :asn_country, :asn_name]

  @impl true
  def collect(%Context{instance: instance, client_ip: ip} = ctx) do
    case lookup(instance.name, ip) do
      nil ->
        Context.put_signals(ctx, %{asn: nil, asn_kind: :unknown})

      %{asn: asn, country: country, name: name} ->
        Context.put_signals(ctx, %{
          asn: asn,
          asn_kind: kind(asn, instance.config),
          asn_country: country,
          asn_name: name
        })
    end
  end

  @doc """
  Returns the ASN entry covering `ip` in the data `instance` loaded, if any.
  """
  @spec lookup(atom(), :inet.ip_address() | nil) :: entry() | nil
  def lookup(_instance, nil), do: nil

  def lookup(instance, ip) do
    case published(instance) do
      nil -> nil
      table -> Table.lookup(table, ip)
    end
  end

  @doc """
  Classifies an ASN as `:hosting` or `:other`.
  """
  @spec kind(pos_integer(), Limen.Config.t()) :: :hosting | :other
  def kind(asn, config) do
    if MapSet.member?(@hosting, asn) or asn in config.asn.hosting,
      do: :hosting,
      else: :other
  end

  # Kept apart from the instance itself, so that loading data does not
  # republish the whole instance. The table is almost all refcounted
  # binaries, so replacing it leaves only a few words in the literal area for
  # processes to be checked against.
  @doc false
  @spec publish(atom(), Table.t()) :: :ok
  def publish(instance, table), do: :persistent_term.put({__MODULE__, instance}, table)

  @doc false
  @spec unpublish(atom()) :: :ok
  def unpublish(instance) do
    _existed = :persistent_term.erase({__MODULE__, instance})
    :ok
  end

  @doc false
  @spec published(atom()) :: Table.t() | nil
  def published(instance), do: :persistent_term.get({__MODULE__, instance}, nil)
end
