defmodule Limen.Maze do
  @moduledoc """
  An endless maze of slow, plausible pages for clients caught misbehaving.

  Clients that fell into a `Limen.Trap`, that a policy sent to the maze, or
  that were banned with `action: :maze`, get maze pages instead of your
  application. A maze page looks like an ordinary page of a website (an
  article, a listing of entries or a directory table) written by a language
  model, and every one of its links leads to another maze page. It is sent
  slowly, a few hundred bytes at a time with pauses in between, so a scraper
  spends its time and its [crawl budget] on pages worth nothing, without being
  told it was caught.

  ## Stable per site, unpredictable elsewhere

  The content of a page is drawn from a random generator seeded with an [HMAC]
  of its path, keyed with the instance's secret (see `Limen.Config.Keys`).
  So, on one site, a page is the same every time it is requested, and
  comparing two fetches reveals nothing; but it differs from one site to
  another and cannot be predicted without the secret, so Limen's maze cannot
  be recognised by recomputing it. With `drift: :daily` or `:weekly`, pages
  change at that pace, like a site being edited. Rotating the secret changes
  every page.

  How a page is delivered is random on every request: where it is cut into
  chunks, how long each pause lasts, and so how long the response takes.

  ## Precomputed, then slow

  The expensive work happens once: the language model (`Limen.Maze.Model`),
  with every word escaped and every choice turned into a
  `Limen.Maze.Dice`, is built at compile time for Limen's bundled corpus, or
  when an instance with a `:corpus` of its own starts. Rendering a page
  takes a fraction of a millisecond. The rest of a maze response is spent asleep:
  the request process sends a chunk, sleeps, and sends the next one, at low
  process priority, until the page is sent or `:max_duration` has passed, in
  which case the rest goes out at once so the client can follow its links
  deeper. A closed connection ends it early.

  At most `:max_concurrent` requests are held in the maze at once, counted
  with `:atomics` (`held/1` reads the count); beyond that, clients get an
  immediate `429`. Nothing on the way calls a process or sends a message.
  See the `:maze` options in `Limen.Config`.

  ## Admission

  Holding connections is cheap, but not free. To stop taking clients in
  when your application is under load, give the maze an `:admit` function,
  `{module, function, args}`: before a client is held, it is called with
  `args` and must return `true` to let it in. Otherwise the client gets the
  same immediate `429` as when the maze is full. It runs on the request
  path, so it must be cheap and must not call a process: read an
  `:atomics` or `:persistent_term` value your application keeps current.

      config :my_app, Limen, maze: [admit: {MyApp.Load, :calm?, []}]

  Every refusal emits a `[:limen, :maze, :refused]` event whose `:reason`
  is `:full` or `:admission` (see `Limen.Telemetry`); an `:admit` function
  that raises refuses the client too.

  ## Links

  Maze links lead under the first trap path of the instance (see
  `Limen.Trap`), so following one is itself a confession; without trap
  paths, they lead below the requested path. Pages carry
  `noindex, nofollow` in a [robots meta tag][robots meta] and an
  `x-robots-tag` header, which ask search engines neither to index them nor
  to follow their links.

  [crawl budget]: https://developers.google.com/search/docs/crawling-indexing/large-site-managing-crawl-budget
  [HMAC]: https://www.rfc-editor.org/rfc/rfc2104
  [robots meta]: https://developers.google.com/search/docs/crawling-indexing/robots-meta-tag
  """

  use Limen.Boundary,
    type: :strict,
    deps: [Limen.Context, Limen.HMAC, Limen.Instance, Limen.Stats, Limen.Telemetry, Plug],
    exports: [Bundled, Dice, Model]

  alias Limen.{Context, Instance}
  alias Limen.Maze.{Bundled, Dice, Model}

  @kinds Dice.new(article: 5, listing: 3, directory: 2)

  # Pages carry dates between these two, whatever the current date, so they
  # do not change from one day to the next.
  @first_day Date.to_gregorian_days(~D[2019-01-01])
  @days 2_400

  @doc false
  @spec setup(atom(), Limen.Config.t()) :: :ok
  def setup(name, %{maze: %{corpus: []}}) do
    teardown(name)
  end

  def setup(name, %{maze: %{corpus: files, bundled_corpus: bundled?}}) do
    texts = Enum.map(files, &File.read!/1)
    texts = if bundled?, do: [Bundled.text() | texts], else: texts
    :persistent_term.put({__MODULE__, name}, Model.build(texts))
  end

  @doc false
  @spec teardown(atom()) :: :ok
  def teardown(name) do
    _existed = :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc """
  The language model `instance` writes its maze with.
  """
  @spec model(Instance.t()) :: Model.t()
  def model(%Instance{config: %{maze: %{corpus: []}}}), do: Bundled.model()
  def model(%Instance{name: name}), do: :persistent_term.get({__MODULE__, name})

  @doc """
  Renders the maze page for `path`, with links under `base`.

  The same instance secret, path and (with `:drift`) period always give the
  same page. `now` is the system time in milliseconds, which only matters
  with `:drift`.
  """
  @spec page(Instance.t(), String.t(), String.t(), integer()) :: iolist()
  def page(%Instance{config: %{maze: config}} = instance, path, base, now) do
    model = model(instance)
    base = Plug.HTML.html_escape(String.trim_trailing(base, "/"))
    state = seed(instance, path, now)
    {kind, state} = Dice.roll(@kinds, state)
    {title, state} = Model.phrase(model, 3..7, state)
    title = Model.render_phrase(model, title)
    page = %{model: model, config: config, base: base}
    {nav, state} = links(page, config.links, 1..2, state)
    {main, state} = main(kind, page, state)
    {aside, state} = aside(page, state)
    {footer, _state} = sentence(page, state)

    [
      "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
      "<meta name=\"robots\" content=\"noindex, nofollow\">\n",
      ["<title>", title, "</title>\n</head>\n<body>\n"],
      ["<header><nav><ul>", Enum.map(nav, &item/1), "</ul></nav></header>\n"],
      ["<main>\n<h1>", title, "</h1>\n", main, "</main>\n"],
      aside,
      ["<footer><p>", footer, "</p></footer>\n</body>\n</html>\n"]
    ]
  end

  defp seed(%Instance{config: %{maze: config}} = instance, path, now),
    do: random(instance, [path | period(config.drift, now)])

  @doc false
  # A random state only the instance's secret can predict, the same for the
  # same subject.
  @spec random(Instance.t(), iodata()) :: :rand.state()
  def random(%Instance{config: %{keys: %{maze: [key | _previous]}}}, subject) do
    <<a::58, b::58, c::58, _rest::bits>> = Limen.HMAC.sha256(key, subject)
    :rand.seed_s(:exsss, {a, b, c})
  end

  @doc false
  # A phrase and its slug for `subject`, stable for the instance.
  @spec name(Instance.t(), iodata(), Range.t()) :: {String.t(), String.t()}
  def name(instance, subject, words) do
    model = model(instance)
    {ids, _state} = Model.phrase(model, words, random(instance, [0, "name", 0, subject]))
    {Model.render_phrase(model, ids), Model.slug(model, ids)}
  end

  defp period(nil, _now), do: []
  defp period(:daily, now), do: [0, Integer.to_string(div(now, 86_400_000))]
  defp period(:weekly, now), do: [0, Integer.to_string(div(now, 604_800_000))]

  defp main(:article, page, state) do
    {date, state} = date(state)

    {count, state} =
      Model.between(elem(page.config.paragraphs, 0), elem(page.config.paragraphs, 1), state)

    {paragraphs, state} = map_state(1..count, state, &section(page, &1, &2))
    {[date, paragraphs], state}
  end

  defp main(:listing, page, state) do
    {count, state} = Model.between(5, 12, state)

    {entries, state} =
      map_state(1..count, state, fn _index, state ->
        {{href, text}, state} = link(page, 3..7, state)
        {summary, state} = sentence(page, state)
        {date, state} = date(state)

        {[
           "<li><h2><a href=\"",
           href,
           "\">",
           text,
           "</a></h2>",
           date,
           "<p>",
           summary,
           "</p></li>\n"
         ], state}
      end)

    {{href, text}, state} = link(page, 2..3, state)
    {["<ul>\n", entries, "</ul>\n<nav><a href=\"", href, "\">", text, "</a></nav>\n"], state}
  end

  defp main(:directory, page, state) do
    {intro, state} = paragraph(page, 1..2, state)
    {headers, state} = map_state(1..3, state, fn _index, state -> phrase(page, 1..2, state) end)
    {count, state} = Model.between(8, 20, state)

    {rows, state} =
      map_state(1..count, state, fn _index, state ->
        {{href, name}, state} = link(page, 2..4, state)
        {kind, state} = phrase(page, 1..3, state)
        {number, state} = Model.between(1, 9_999, state)

        {[
           "<tr><td><a href=\"",
           href,
           "\">",
           name,
           "</a></td><td>",
           kind,
           "</td><td>",
           Integer.to_string(number),
           "</td></tr>\n"
         ], state}
      end)

    header = Enum.map(headers, &["<th>", &1, "</th>"])

    {[
       intro,
       "<table>\n<thead><tr>",
       header,
       "</tr></thead>\n<tbody>\n",
       rows,
       "</tbody>\n</table>\n"
     ], state}
  end

  # Articles start with a paragraph; later ones sometimes get a heading.
  defp section(page, 1, state), do: paragraph(page, 3..6, state)

  defp section(page, _index, state) do
    {roll, state} = :rand.uniform_s(4, state)
    {paragraph, state} = paragraph(page, 2..6, state)

    if roll == 1 do
      {heading, state} = phrase(page, 2..5, state)
      {["<h2>", heading, "</h2>\n", paragraph], state}
    else
      {paragraph, state}
    end
  end

  defp paragraph(page, min..max//_step, state) do
    {count, state} = Model.between(min, max, state)
    {sentences, state} = map_state(1..count, state, fn _index, state -> sentence(page, state) end)
    {["<p>", Enum.intersperse(sentences, " "), "</p>\n"], state}
  end

  # One sentence in five links a few of its words deeper into the maze.
  defp sentence(%{model: model} = page, state) do
    {ids, state} = Model.sentence(model, state)
    {roll, state} = :rand.uniform_s(5, state)

    if roll == 1 and length(ids) >= 6 do
      {start, state} = Model.between(1, length(ids) - 4, state)
      {length, state} = Model.between(2, 3, state)
      {before, rest} = Enum.split(ids, start)
      {span, rest} = Enum.split(rest, length)
      {href, state} = href(page, span, state)

      {[
         Model.words(model, before),
         " <a href=\"",
         href,
         "\">",
         Model.words(model, span),
         "</a> ",
         Model.render(model, rest)
       ], state}
    else
      {Model.render(model, ids), state}
    end
  end

  defp aside(page, state) do
    {heading, state} = phrase(page, 1..3, state)
    {related, state} = links(page, page.config.links, 2..5, state)
    {["<aside><h2>", heading, "</h2><ul>", Enum.map(related, &item/1), "</ul></aside>\n"], state}
  end

  defp links(page, {min, max}, words, state) do
    {count, state} = Model.between(min, max, state)
    map_state(1..count, state, fn _index, state -> link(page, words, state) end)
  end

  defp link(%{model: model} = page, words, state) do
    {ids, state} = Model.phrase(model, words, state)
    {href, state} = href(page, ids, state)
    {{href, Model.render_phrase(model, ids)}, state}
  end

  # Slugs from the linked words, most of them with a number, like the ids of
  # a content management system.
  defp href(%{model: model, base: base}, ids, state) do
    {number, state} = Model.between(2, 9_999, state)
    {roll, state} = :rand.uniform_s(5, state)

    slug =
      case {Model.slug(model, ids), roll} do
        {"", _roll} -> Integer.to_string(number)
        {slug, roll} when roll <= 3 -> slug <> "-" <> Integer.to_string(number)
        {slug, _roll} -> slug
      end

    {[base, "/", slug], state}
  end

  defp phrase(%{model: model}, words, state) do
    {ids, state} = Model.phrase(model, words, state)
    {Model.render_phrase(model, ids), state}
  end

  defp item({href, text}), do: ["<li><a href=\"", href, "\">", text, "</a></li>"]

  defp date(state) do
    {offset, state} = :rand.uniform_s(@days, state)
    date = Date.to_iso8601(Date.from_gregorian_days(@first_day + offset))
    {["<p><time datetime=\"", date, "\">", date, "</time></p>\n"], state}
  end

  defp map_state(range, state, fun), do: Enum.map_reduce(range, state, fun)

  @doc """
  The number of requests `instance` currently holds in the maze.
  """
  @spec held(atom() | Instance.t()) :: non_neg_integer()
  def held(instance), do: :atomics.get(Instance.fetch!(instance).maze, 1)

  @doc """
  Sends the maze page for the request to the client, slowly.

  Returns the halted connection. Clients beyond `:max_concurrent`, or that
  the `:admit` function turns away, get an immediate `429` instead.
  """
  @spec serve(Plug.Conn.t(), Context.t(), String.t()) :: Plug.Conn.t()
  def serve(conn, %Context{instance: %Instance{maze: held} = instance} = ctx, base) do
    %{max_concurrent: max_concurrent, admit: admit} = instance.config.maze

    cond do
      not admitted?(admit) ->
        refuse(conn, ctx, :admission)

      :atomics.add_get(held, 1, 1) <= max_concurrent ->
        try do
          deliver(conn, ctx, base)
        after
          :atomics.sub(held, 1, 1)
        end

      true ->
        :atomics.sub(held, 1, 1)
        refuse(conn, ctx, :full)
    end
  end

  defp admitted?(nil), do: true

  defp admitted?({module, function, args}) do
    apply(module, function, args) == true
  rescue
    _exception -> false
  end

  defp refuse(conn, %Context{instance: instance} = ctx, reason) do
    Limen.Stats.incr(instance, :maze_refused)

    Limen.Telemetry.execute(instance.name, [:maze, :refused], %{count: 1}, %{
      reason: reason,
      path: ctx.path,
      identity: Context.identity(ctx)
    })

    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.put_resp_header("retry-after", "60")
    |> Plug.Conn.send_resp(429, "Too Many Requests")
    |> Plug.Conn.halt()
  end

  defp deliver(conn, %Context{instance: instance} = ctx, base) do
    started = System.monotonic_time()
    config = instance.config.maze
    # Real traffic comes first; a maze response is only ever waiting.
    priority = Process.flag(:priority, :low)

    try do
      page = IO.iodata_to_binary(page(instance, ctx.path, base, ctx.now))

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.put_resp_header("x-robots-tag", "noindex, nofollow")
        |> Plug.Conn.send_chunked(200)

      deadline = System.monotonic_time(:millisecond) + config.max_duration
      {conn, result, sent} = drip(conn, page, config, deadline, %{bytes: 0, chunks: 0})
      Limen.Stats.incr(instance, :maze_served)

      Limen.Telemetry.execute(
        instance.name,
        [:maze, :served],
        Map.put(sent, :duration, System.monotonic_time() - started),
        %{result: result, path: ctx.path, identity: Context.identity(ctx)}
      )

      Plug.Conn.halt(conn)
    after
      Process.flag(:priority, priority)
    end
  end

  # Once the deadline passes, the rest goes out at once.
  defp drip(conn, page, config, deadline, sent) do
    late? = System.monotonic_time(:millisecond) >= deadline
    {part, rest} = if late?, do: {page, ""}, else: cut(page, config.chunk)

    case Plug.Conn.chunk(conn, part) do
      {:ok, conn} ->
        sent = %{bytes: sent.bytes + byte_size(part), chunks: sent.chunks + 1}

        cond do
          rest != "" ->
            pause(config.delay, deadline)
            drip(conn, rest, config, deadline, sent)

          late? ->
            {conn, :deadline, sent}

          true ->
            {conn, :complete, sent}
        end

      {:error, _closed} ->
        {conn, :closed, sent}
    end
  end

  defp cut(page, {min, max}) do
    size = max(min + :rand.uniform(max - min + 1) - 1, 1)

    if byte_size(page) <= size,
      do: {page, ""},
      else: {binary_part(page, 0, size), binary_part(page, size, byte_size(page) - size)}
  end

  defp pause({min, max}, deadline) do
    left = deadline - System.monotonic_time(:millisecond)
    Process.sleep(max(min(min + :rand.uniform(max - min + 1) - 1, left), 0))
  end
end
