defmodule Limen.MazeTest do
  use Limen.Case, async: true

  alias Limen.{Context, Maze}

  @moduletag config: [maze: [delay: {0, 0}], trap: [paths: ["/archive"]]]
  @day 86_400_000

  defp page(instance, path, base \\ "/archive", now \\ 0),
    do: IO.iodata_to_binary(Maze.page(instance, path, base, now))

  defp other_instance(context, config) do
    name = :"#{context.limen}_other"

    defaults = [
      decision_log: [non_allow_sample_rate: 0.0],
      secret_key: String.duplicate("maze test", 4)
    ]

    config = Keyword.merge(defaults, config)
    start_supervised!({Limen, name: name, config: config}, id: name)
    instance(name)
  end

  describe "pages" do
    test "are the same every time for a site and path", %{instance: instance} do
      assert page(instance, "/archive/a") == page(instance, "/archive/a")
      refute page(instance, "/archive/a") == page(instance, "/archive/b")
    end

    test "differ from one site to another", %{instance: instance} = context do
      other = other_instance(context, secret_key: String.duplicate("another site", 3))
      refute page(instance, "/archive/a") == page(other, "/archive/a")
    end

    @tag config: [maze: [drift: :daily]]
    test "drift at the configured pace", %{instance: instance} do
      assert page(instance, "/archive/a", "/archive", 10) ==
               page(instance, "/archive/a", "/archive", @day - 1)

      refute page(instance, "/archive/a", "/archive", 10) ==
               page(instance, "/archive/a", "/archive", @day + 10)
    end

    test "look like a page whose links all lead deeper", %{instance: instance} do
      document = LazyHTML.from_document(page(instance, "/archive/some-entry"))
      hrefs = LazyHTML.attribute(LazyHTML.query(document, "a"), "href")

      assert length(hrefs) >= 8
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/archive/"))
      assert LazyHTML.text(LazyHTML.query(document, "title")) != ""

      assert Enum.count(
               LazyHTML.query(document, "meta[name=robots][content='noindex, nofollow']")
             ) ==
               1
    end

    test "escape the base of their links", %{instance: instance} do
      html = page(instance, "/x", ~s(/a"b))
      refute html =~ ~s(/a"b)
      assert html =~ "/a&quot;b/"
    end

    test "can be written with the site's own words", %{instance: instance} = context do
      corpus = Path.join(System.tmp_dir!(), "limen-corpus-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(corpus) end)

      File.write!(corpus, """
      The zebrafish lantern glows above the quartz harbour every evening.
      Every quartz harbour keeps a zebrafish lantern for the evening boats.
      The evening boats follow the lantern into the harbour.
      """)

      other = other_instance(context, maze: [corpus: [corpus], bundled_corpus: false])
      html = page(other, "/archive/a")
      assert html =~ "zebrafish" or html =~ "quartz" or html =~ "lantern"
      refute html =~ "newsletter"
      refute page(instance, "/archive/a") =~ "zebrafish"
    end
  end

  describe "serving" do
    defp serve(instance, path \\ "/archive/entry") do
      conn = conn(:get, path)
      ctx = %Context{instance: instance, path: path, now: 0}
      Maze.serve(conn, ctx, "/archive")
    end

    @tag config: [maze: [delay: {0, 0}, chunk: {16, 64}]]
    test "sends the page in small chunks", %{instance: instance} do
      capture_events([[:limen, :maze, :served]], instance.name)
      conn = serve(instance)

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.halted
      assert conn.resp_body == page(instance, "/archive/entry")
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]

      assert_receive {:event, [:limen, :maze, :served], %{bytes: bytes, chunks: chunks},
                      %{result: :complete}}

      assert bytes == byte_size(conn.resp_body)
      assert chunks > div(bytes, 64)
      assert Limen.Stats.snapshot(instance).maze_served == 1
    end

    @tag config: [maze: [delay: {30, 30}, chunk: {16, 16}, max_duration: 50]]
    test "sends the rest at once when the time is up", %{instance: instance} do
      capture_events([[:limen, :maze, :served]], instance.name)
      conn = serve(instance)

      assert conn.resp_body == page(instance, "/archive/entry")

      assert_receive {:event, [:limen, :maze, :served], %{duration: duration},
                      %{result: :deadline}}

      assert System.convert_time_unit(duration, :native, :millisecond) < 1_000
    end

    @tag config: [maze: [delay: {0, 0}, max_concurrent: 2]]
    test "refuses clients beyond the concurrency limit", %{instance: instance} do
      :atomics.put(instance.maze, 1, 2)
      conn = serve(instance)

      assert conn.status == 429
      assert :atomics.get(instance.maze, 1) == 2
      assert Limen.Stats.snapshot(instance).maze_refused == 1

      :atomics.put(instance.maze, 1, 0)
      assert serve(instance).status == 200
      assert :atomics.get(instance.maze, 1) == 0
    end

    test "restores the process priority", %{instance: instance} do
      previous = Process.flag(:priority, :normal)
      serve(instance)
      assert Process.flag(:priority, previous) == :normal
    end
  end
end
