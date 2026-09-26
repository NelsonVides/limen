defmodule Limen.Signal.Asn do
  @moduledoc """
  Maps the client address to its autonomous system (ASN).

  An [autonomous system][ASN] is a network run by one operator, such as a
  cloud provider, a hosting company or an ISP, and identified on the internet
  by its number.

  Traffic from hosting providers and clouds is far more likely to be
  automated than traffic from residential and mobile networks. This signal
  looks the client address up in an IP-to-ASN table and classifies the ASN.

  The table lives in an ETS `ordered_set` keyed by range start, so a lookup
  is one `:ets.prev/2` and one `:ets.lookup/2`. It is loaded off the request
  path by `Limen.Signal.Asn.Loader` from the `:file` option of the `:asn`
  configuration, in the format of the [iptoasn.com][iptoasn]
  `ip2asn-combined.tsv` dataset (optionally gzipped):

      range_start<TAB>range_end<TAB>asn<TAB>country<TAB>description

  The full dataset has around 700,000 ranges and takes in the order of
  100 MB of memory.

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

  alias Limen.{Context, IP}

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

  @type entry :: %{asn: pos_integer(), country: String.t(), name: String.t()}

  @impl true
  def provides, do: [:asn, :asn_kind, :asn_country, :asn_name]

  @impl true
  def collect(%Context{instance: instance, client_ip: ip} = ctx) do
    case lookup(instance.name, ip) do
      nil ->
        ctx
        |> Context.put_signal(:asn, nil)
        |> Context.put_signal(:asn_kind, :unknown)

      %{asn: asn, country: country, name: name} ->
        ctx
        |> Context.put_signal(:asn, asn)
        |> Context.put_signal(:asn_kind, kind(asn, instance.config))
        |> Context.put_signal(:asn_country, country)
        |> Context.put_signal(:asn_name, name)
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
      {ranges, names} -> find(ranges, names, IP.to_integer(ip))
    end
  end

  defp find(ranges, names, {version, n}) do
    with {^version, _start} = start <- :ets.prev(ranges, {version, n + 1}),
         [{^start, last, asn, country}] when n <= last <- :ets.lookup(ranges, start) do
      name =
        case :ets.lookup(names, asn) do
          [{^asn, name}] -> name
          [] -> nil
        end

      %{asn: asn, country: country, name: name}
    else
      _no_range -> nil
    end
  rescue
    # The table was replaced by a reload while this lookup was running.
    ArgumentError -> nil
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
  # republish the whole instance.
  @doc false
  @spec publish(atom(), {:ets.table(), :ets.table()}) :: :ok
  def publish(instance, tables), do: :persistent_term.put({__MODULE__, instance}, tables)

  @doc false
  @spec unpublish(atom()) :: :ok
  def unpublish(instance) do
    _existed = :persistent_term.erase({__MODULE__, instance})
    :ok
  end

  @doc false
  @spec published(atom()) :: {:ets.table(), :ets.table()} | nil
  def published(instance), do: :persistent_term.get({__MODULE__, instance}, nil)
end
