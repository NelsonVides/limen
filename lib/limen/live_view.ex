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

    With a `:policy`, its `trust` rules are checked first, with the facts
    stated by `put_facts/2` in an earlier hook, so that clients the HTTP
    gate trusts (say, signed-in users) connect whatever their token, as
    they browse whatever their prefix:

        live_session :default,
          on_mount: [MyAppWeb.LimenFacts, {Limen.LiveView, otp_app: :my_app, policy: MyApp.BotPolicy}] do
          ...
        end

    Only connected mounts are checked; the initial HTTP render went through
    `Limen.Plug`. A connection that fails the check is redirected to the page
    it was mounting, which takes the client back through the HTTP gate (and
    its challenge, if needed). LiveView does not give hooks the page's URL,
    so it is rebuilt from the route the view is mounted at and its
    parameters; a view rendered outside the router goes to `/`.

    The hook also keeps the connection's connect info, which LiveView only
    exposes while mounting, so that `check_form/3` can check form traps (see
    `Limen.Trap`) in `handle_event/3`. The connect info describes the
    socket, whose URI is the socket's own (`/live/websocket`), so for views
    mounted at the router the hook also follows the page's URL as LiveView
    reports it to `handle_params/3`, and form checks record the page's path.
    """

    import Phoenix.LiveView

    alias Plug.Conn.Query

    @doc """
    States facts about the connection, as `Limen.put_facts/2` does for
    requests.

    Call it from an `on_mount` hook that runs before this module's, such as
    the one that loads the signed-in user:

        live_session :default,
          on_mount: [{MyAppWeb.UserAuth, :mount_current_user}, MyAppWeb.LimenFacts,
                     {Limen.LiveView, otp_app: :my_app, policy: MyApp.BotPolicy}] do
          ...
        end

        defmodule MyAppWeb.LimenFacts do
          def on_mount(:default, _params, _session, socket) do
            {:cont, Limen.LiveView.put_facts(socket, signed_in: socket.assigns.current_user != nil)}
          end
        end

    The socket check and `check_form/3` record them in their decisions, and
    the `trust` rules of the hook's `:policy` can use them.
    """
    @spec put_facts(Phoenix.LiveView.Socket.t(), map() | keyword()) ::
            Phoenix.LiveView.Socket.t()
    def put_facts(socket, facts) do
      facts = Limen.Context.merge_facts(socket.private[:limen_facts] || %{}, facts)
      put_private(socket, :limen_facts, facts)
    end

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

    @doc """
    Checks a form submitted to a LiveView for the tells of
    `Limen.Trap.form_fields/2`, see `Limen.Trap.check_form/3`.

        def handle_event("save", params, socket) do
          case Limen.LiveView.check_form(socket, params, otp_app: :my_app) do
            {:ok, _decision} -> save(socket, params)
            {:trapped, _decision} -> {:noreply, pretend_it_worked(socket)}
          end
        end

    LiveView only gives access to connect info while mounting, so the socket
    must have been mounted with the `on_mount` hook of this module, which
    keeps the connect info `Limen.Socket` documents for later checks.
    Options are those of `Limen.Trap.check_form/3`, where `:instance` or
    `:otp_app` is required.
    """
    @spec check_form(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
            {:ok, Limen.Decision.t()} | {:trapped, Limen.Decision.t()}
    def check_form(socket, params, opts) do
      connect_info = socket.private[:limen_connect_info] || connect_info(socket)
      Limen.Trap.check_form(connect_info, params, with_facts(opts, socket))
    end

    defp with_facts(opts, socket),
      do: Keyword.put_new(opts, :facts, socket.private[:limen_facts] || %{})

    defp connect_info(socket) do
      %{
        peer_data: get_connect_info(socket, :peer_data),
        x_headers: get_connect_info(socket, :x_headers),
        user_agent: get_connect_info(socket, :user_agent),
        uri: get_connect_info(socket, :uri)
      }
    end

    defp check(socket, params, opts) do
      connect_info = connect_info(socket)

      connect_params = get_connect_params(socket) || %{}

      case Limen.Socket.check(connect_info, connect_params, with_facts(opts, socket)) do
        {:ok, _decision} ->
          socket = put_private(socket, :limen_connect_info, connect_info)
          {:cont, follow_page(socket)}

        {:error, _decision} ->
          {:halt, redirect(socket, to: page_path(socket, params))}
      end
    end

    # LiveView tells a view its URL in handle_params, after mounting and on
    # every live navigation; only views mounted at the router get it.
    defp follow_page(%{router: nil} = socket), do: socket

    defp follow_page(socket),
      do: attach_hook(socket, :limen_page, :handle_params, &__MODULE__.__handle_params__/3)

    @doc false
    @spec __handle_params__(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
            {:cont, Phoenix.LiveView.Socket.t()}
    def __handle_params__(_params, uri, socket) do
      case socket.private[:limen_connect_info] do
        %{} = info ->
          {:cont, put_private(socket, :limen_connect_info, %{info | uri: URI.parse(uri)})}

        nil ->
          {:cont, socket}
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
