defmodule Limen.Signal.AsnTest do
  use Limen.Case, async: true

  alias Limen.Context
  alias Limen.Signal.Asn
  alias Limen.Signal.Asn.Loader

  @fixture Path.expand("../../fixtures/ip2asn-sample.tsv", __DIR__)

  test "loads ranges and looks addresses up", %{limen: limen} do
    assert {:ok, 4} = Loader.load(limen, @fixture)

    assert %{asn: 16_509, country: "US", name: "AMAZON-02"} = Asn.lookup(limen, {3, 5, 140, 2})
    assert %{asn: 13_335} = Asn.lookup(limen, {1, 0, 0, 255})
    assert %{asn: 64_500, country: "ZZ"} = Asn.lookup(limen, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    assert Asn.lookup(limen, {1, 0, 1, 0}) == nil
    assert Asn.lookup(limen, {192, 0, 2, 1}) == nil
    assert Asn.lookup(limen, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1}) == nil
    assert Asn.lookup(limen, {0, 0, 0, 1}) == nil
  end

  test "loads gzipped files", %{limen: limen} do
    path = Path.join(System.tmp_dir!(), "limen-asn-#{System.unique_integer([:positive])}.tsv.gz")
    File.write!(path, :zlib.gzip(File.read!(@fixture)))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, 4} = Loader.load(limen, path)
    assert %{asn: 15_169} = Asn.lookup(limen, {8, 8, 8, 8})
  end

  test "recognises gzip by its content, and skips malformed lines", %{limen: limen} do
    dir = Path.join(System.tmp_dir!(), "limen-asn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    plain = Path.join(dir, "plain.part")
    File.write!(plain, "malformed\n" <> File.read!(@fixture) <> "1.2.3.4\tnot\ta row\n")
    gzipped = Path.join(dir, "gzipped.part")
    File.write!(gzipped, :zlib.gzip(File.read!(plain)))

    for file <- [plain, gzipped] do
      assert {:ok, 4} = Loader.load(limen, file)
      assert %{asn: 64_500} = Asn.lookup(limen, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end
  end

  test "a reload replaces the table", %{limen: limen} do
    {:ok, 1} = Loader.load_rows(limen, [{"8.8.8.0", "8.8.8.255", 15_169, "US", "GOOGLE"}])
    {:ok, 1} = Loader.load_rows(limen, [{"8.8.4.0", "8.8.4.255", 15_169, "US", "GOOGLE"}])

    assert Asn.lookup(limen, {8, 8, 8, 8}) == nil
    assert %{asn: 15_169} = Asn.lookup(limen, {8, 8, 4, 4})
  end

  test "reports load errors without replacing the table", %{limen: limen} do
    {:ok, 1} = Loader.load_rows(limen, [{"8.8.8.0", "8.8.8.255", 15_169, "US", "GOOGLE"}])
    assert {:error, _message} = Loader.load(limen, "/does/not/exist.tsv")
    assert %{asn: 15_169} = Asn.lookup(limen, {8, 8, 8, 8})
  end

  @tag config: [asn: [hosting: [13_335]]]
  test "classifies hosting providers, including configured ones", %{limen: limen} do
    {:ok, _count} = Loader.load(limen, @fixture)

    assert signals(limen, {3, 1, 1, 1}) == %{
             asn: 16_509,
             asn_kind: :hosting,
             asn_country: "US",
             asn_name: "AMAZON-02"
           }

    assert %{asn_kind: :hosting} = signals(limen, {1, 0, 0, 1})
    assert %{asn_kind: :other} = signals(limen, {8, 8, 8, 8})
    assert signals(limen, {9, 9, 9, 9}) == %{asn: nil, asn_kind: :unknown}
  end

  defmodule GeoSource do
    @behaviour Limen.Signal.Asn.Source

    @impl true
    def lookup(_instance, {192, 0, 2, 1}), do: %{asn: 16_509, country: "IE", name: "AMAZON"}

    def lookup(_instance, {192, 0, 2, 2}),
      do: %{asn: 64_496, name: "Rack Rentals", kind: :hosting}

    def lookup(_instance, {192, 0, 2, 3}), do: %{country: "PL"}
    def lookup(_instance, {192, 0, 2, 4}), do: raise("database not loaded")
    def lookup(_instance, _ip), do: nil
  end

  @tag config: [asn: [source: GeoSource, hosting: [64_497]]]
  test "reads another source when configured", %{limen: limen} do
    assert collect(limen, {192, 0, 2, 1}).signals == %{
             asn: 16_509,
             asn_kind: :hosting,
             asn_country: "IE",
             asn_name: "AMAZON"
           }

    # The source's own classification wins.
    assert %{asn: 64_496, asn_kind: :hosting} = collect(limen, {192, 0, 2, 2}).signals

    assert %{asn: nil, asn_kind: :unknown, asn_country: "PL"} =
             collect(limen, {192, 0, 2, 3}).signals

    unknown = collect(limen, {198, 51, 100, 1})
    assert unknown.signals == %{asn: nil, asn_kind: :unknown}
    assert unknown.evidence.asn == %{source: GeoSource}

    failed = collect(limen, {192, 0, 2, 4})
    assert failed.signals == %{asn: nil, asn_kind: :unknown}
    assert failed.evidence.asn == %{source: GeoSource, error: "database not loaded"}
  end

  test "the default source's data options need the default source" do
    assert_raise ArgumentError, ~r/:file and :url are the default source's/, fn ->
      Limen.Config.build(asn: [source: GeoSource, file: "/tmp/ip2asn.tsv"])
    end

    assert_raise ArgumentError, ~r/invalid value for :source/, fn ->
      Limen.Config.build(asn: [source: Enum])
    end
  end

  defp collect(limen, ip), do: Asn.collect(%Context{instance: instance(limen), client_ip: ip})

  defp signals(limen, ip), do: collect(limen, ip).signals
end
