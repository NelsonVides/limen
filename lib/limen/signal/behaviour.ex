defmodule Limen.Signal.Behaviour do
  @moduledoc """
  What each client prefix has been doing over the last minute.

  `track/2` runs for every request Limen sees (including requests that take
  the pass cookie fast path, and routes in `:track` mode) and counts, per
  prefix, in the sliding minute window of `Limen.State.Window`:

    * requests;
    * pages (navigations) and assets (scripts, styles, images, fonts);
    * distinct paths, deduplicated with a rotating Bloom filter
      (`Limen.Sketch.RotatingBloom`);
    * `404 Not Found` responses, counted when the response is sent.

  The counts share one row per prefix (see `key/1`), so counting a request
  costs one table update, and reading the counts back costs nothing. It also
  counts requests per JA4 fingerprint, for dashboards, and adds the prefix to
  the HyperLogLog behind `Limen.State.active_prefixes/1`.

  `collect/1` turns the counts into signals. Scrapers tend to fetch many
  pages and few assets, and to probe paths that do not exist; browsers load
  a page's assets (unless they are cached, which makes a low asset ratio a
  weak signal on its own).

  Provides `:requests_per_minute`, `:pages_per_minute`, `:assets_per_minute`,
  `:asset_ratio` (assets per page, `nil` before any page), `:not_found_ratio`
  (404s per request), `:distinct_paths_per_minute` (a path revisited within
  two minutes is not counted again) and `:active_prefixes` (distinct client
  prefixes the instance saw on this node over the last one to two minutes; a
  sudden jump suggests a distributed flood).
  """

  @behaviour Limen.Signal

  alias Limen.Context
  alias Limen.State
  alias Limen.State.Window

  @assets ~w(.js .mjs .css .map .png .jpg .jpeg .gif .svg .webp .avif .ico .woff .woff2 .ttf .otf
             .mp4 .webm .mp3 .wasm)
  @asset_destinations ~w(script style image font audio video worker manifest)

  @impl true
  def provides do
    [
      :requests_per_minute,
      :pages_per_minute,
      :assets_per_minute,
      :asset_ratio,
      :not_found_ratio,
      :distinct_paths_per_minute,
      :active_prefixes
    ]
  end

  @doc """
  Counts the request and arranges for a `404` response to be counted.
  """
  @spec track(Plug.Conn.t(), Context.t()) :: {Plug.Conn.t(), Context.t()}
  def track(conn, %Context{instance: instance, prefix: prefix, now: now} = ctx) do
    new_path = State.observe_client(instance, prefix, ctx.path, now)
    counts = Window.add(instance, :minute, key(prefix), increments(kind(ctx), new_path), now)
    count_ja4(instance, ctx.ja4, now)

    conn =
      Plug.Conn.register_before_send(conn, fn conn ->
        if conn.status == 404, do: count_not_found(instance, prefix, now)
        conn
      end)

    {conn, %{ctx | rates: Map.put(ctx.rates, :behaviour, counts)}}
  end

  defp count_ja4(_instance, nil, _now), do: :ok

  defp count_ja4(instance, ja4, now) do
    _count = Window.incr(instance, :minute, {:limen_ja4, ja4}, now)
    :ok
  end

  defp count_not_found(instance, prefix, now) do
    _counts = Window.add(instance, :minute, key(prefix), {0, 0, 0, 1, 0}, now)
    :ok
  end

  defp increments(:page, new_path), do: {1, 1, 0, 0, one(new_path)}
  defp increments(:asset, new_path), do: {1, 0, 1, 0, one(new_path)}
  defp increments(:other, new_path), do: {1, 0, 0, 0, one(new_path)}

  defp one(true), do: 1
  defp one(false), do: 0

  @impl true
  def collect(%Context{instance: instance, prefix: prefix, now: now} = ctx) do
    {requests, pages, assets, not_found, paths} =
      Map.get_lazy(ctx.rates, :behaviour, fn ->
        Window.read(instance, :minute, key(prefix), 5, now)
      end)

    ctx
    |> Context.put_signal(:requests_per_minute, requests)
    |> Context.put_signal(:pages_per_minute, pages)
    |> Context.put_signal(:assets_per_minute, assets)
    |> Context.put_signal(:asset_ratio, if(pages > 0, do: ratio(assets, pages)))
    |> Context.put_signal(:not_found_ratio, ratio(not_found, requests))
    |> Context.put_signal(:distinct_paths_per_minute, paths)
    |> Context.put_signal(:active_prefixes, State.active_prefixes(instance))
  end

  @doc """
  The window key of a prefix's counts.

  They share one row of the minute window, so that counting a request costs
  one table update: requests, pages, assets, `404` responses and new paths,
  in that order.
  """
  @spec key(term()) :: {:limen_behaviour, term()}
  def key(prefix), do: {:limen_behaviour, prefix}

  @doc """
  Classifies a request as a `:page` navigation, an `:asset` or `:other`.

  Uses [`sec-fetch-dest`](https://www.w3.org/TR/fetch-metadata/#sec-fetch-dest-header)
  when the client sends it and the path extension otherwise.
  """
  @spec kind(Context.t()) :: :page | :asset | :other
  def kind(%Context{} = ctx) do
    case Context.header(ctx, "sec-fetch-dest") do
      "document" -> :page
      dest when dest in @asset_destinations -> :asset
      nil -> kind_from_path(ctx)
      _other -> :other
    end
  end

  defp kind_from_path(%Context{method: "GET", path: path}) do
    case Path.extname(path) do
      "" -> :page
      ext when ext in [".html", ".htm"] -> :page
      ext -> if String.downcase(ext) in @assets, do: :asset, else: :other
    end
  end

  defp kind_from_path(_ctx), do: :other

  defp ratio(_count, 0), do: 0.0
  defp ratio(count, total), do: Float.round(count / total, 2)
end
