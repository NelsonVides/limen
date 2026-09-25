if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Limen.LiveView do
    @moduledoc """
    Gates LiveView connections, see `Limen.Socket`.

    In the root layout, embed the socket token:

        <meta name="limen-socket" content={Limen.LiveView.token(@conn)} />

    in `app.js`, send it when connecting:

        const limen = document.querySelector("meta[name='limen-socket']")?.content
        const liveSocket = new LiveSocket("/live", Socket, {
          params: {_csrf_token: csrfToken, _limen: limen}
        })

    configure the socket's connect info in the endpoint:

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [:peer_data, :x_headers, :user_agent, :uri, session: @session]]

    and check connections in the router, with the instance that gates the
    pages (see `Limen.Socket.check/3` for the options):

        live_session :default, on_mount: {Limen.LiveView, otp_app: :my_app} do
          ...
        end

    Only connected mounts are checked; the initial HTTP render went through
    `Limen.Plug`. A connection that fails the check is redirected to the page
    it was mounting, which takes the client back through the HTTP gate (and
    its challenge, if needed). LiveView does not give hooks the page's URL,
    so it is rebuilt from the route the view is mounted at and its
    parameters; a view rendered outside the router goes to `/`.
    """

    import Phoenix.LiveView

    alias Plug.Conn.Query

    @doc """
    Issues the socket token for the page being rendered, see
    `Limen.Socket.token/2`.
    """
    @spec token(Plug.Conn.t(), keyword()) :: String.t() | nil
    defdelegate token(conn, opts \\ []), to: Limen.Socket

    @doc false
    @spec on_mount(keyword(), map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
    def on_mount(opts, params, _session, socket) when is_list(opts) do
      if connected?(socket), do: check(socket, params, opts), else: {:cont, socket}
    end

    def on_mount(_default, _params, _session, _socket) do
      raise ArgumentError,
            "Limen.LiveView needs the instance to check with, use " <>
              "on_mount: {Limen.LiveView, instance: name} or {Limen.LiveView, otp_app: app}"
    end

    defp check(socket, params, opts) do
      connect_info = %{
        peer_data: get_connect_info(socket, :peer_data),
        x_headers: get_connect_info(socket, :x_headers),
        user_agent: get_connect_info(socket, :user_agent),
        uri: get_connect_info(socket, :uri)
      }

      case Limen.Socket.check(connect_info, get_connect_params(socket) || %{}, opts) do
        {:ok, _decision} -> {:cont, socket}
        {:error, _decision} -> {:halt, redirect(socket, to: page_path(socket, params))}
      end
    end

    # The connect info's URI is the socket's own, and LiveView only tells a
    # view its URL after mounting. Among the routes to the view, the one
    # that takes the most parameters in its path wins, and the others go in
    # the query, as they came.
    defp page_path(%{router: router, view: view} = socket, params)
         when router != nil and is_map(params) do
      action = socket.assigns[:live_action]

      router
      |> Phoenix.Router.routes()
      |> Enum.filter(&match?(%{metadata: %{phoenix_live_view: {^view, ^action, _, _}}}, &1))
      |> Enum.flat_map(&build_path(&1.path, params))
      |> Enum.min_by(fn {_path, query} -> map_size(query) end, fn -> {"/", %{}} end)
      |> then(fn
        {path, query} when query == %{} -> path
        {path, query} -> path <> "?" <> Query.encode(query)
      end)
    end

    defp page_path(_socket, _params), do: "/"

    defp build_path(pattern, params) do
      segments = for segment <- String.split(pattern, "/", trim: true), do: fill(segment, params)

      if :error in segments do
        []
      else
        {parts, names} = Enum.unzip(segments)
        [{"/" <> Enum.join(parts, "/"), Map.drop(params, names)}]
      end
    end

    # Route segments are literal, `:param`, `*glob`, or either after a
    # literal prefix.
    defp fill(segment, params) do
      case Regex.run(~r/^([^:*]*)([:*])(.+)$/, segment, capture: :all_but_first) do
        nil -> {segment, nil}
        [prefix, kind, name] -> fill(prefix, kind, name, Map.get(params, name))
      end
    end

    defp fill(prefix, ":", name, value) when is_binary(value), do: {prefix <> encode(value), name}

    defp fill(prefix, "*", name, values) when is_list(values),
      do: {prefix <> Enum.map_join(values, "/", &encode/1), name}

    defp fill(_prefix, _kind, _name, _value), do: :error

    defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
  end
end
