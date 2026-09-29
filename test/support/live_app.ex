defmodule Limen.Test.LiveApp do
  @moduledoc """
  A Phoenix application gated as the guides recommend: a `Limen.Plug` in
  the endpoint serving Limen's own paths, and one in the router pipeline
  after the facts, a LiveView checking forms, for the
  `#{inspect(:limen_live_test)}` instance.
  """

  @doc """
  The instance the application uses.
  """
  def instance, do: :limen_live_test

  defmodule Policy do
    @moduledoc false
    use Limen.Policy, signals: [Limen.Signal.HttpShape]

    trust(:signed_in, when: fact(:signed_in) == true)
    score :no_user_agent, 50, when: shape_flag(:no_user_agent)

    decide do
      score >= 50 -> {:challenge, difficulty: 8}
      true -> :allow
    end
  end

  defmodule Facts do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts),
      do: Limen.put_facts(conn, signed_in: get_session(conn, "signed_in") == true)

    def on_mount(:default, _params, session, socket) do
      {:cont, Limen.LiveView.put_facts(socket, signed_in: session["signed_in"] == true)}
    end
  end

  defmodule SignupLive do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, _session, socket), do: {:ok, assign(socket, result: nil)}

    def render(assigns) do
      ~H"""
      <form id="signup" phx-submit="save">
        {Limen.Trap.form_fields(:limen_live_test)}
        <input type="email" name="email" value="" />
      </form>
      <p id="result">{@result}</p>
      """
    end

    def handle_event("save", params, socket) do
      result =
        case Limen.LiveView.check_form(socket, params, instance: :limen_live_test) do
          {:ok, _decision} -> "saved"
          {:trapped, _decision} -> "saved, pretending"
        end

      {:noreply, assign(socket, result: result)}
    end
  end

  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    import Phoenix.LiveView.Router

    pipeline :browser do
      plug :fetch_session
      plug Facts
      plug Limen.Plug, instance: :limen_live_test, policy: Policy
    end

    scope "/" do
      pipe_through(:browser)

      live_session :default,
        on_mount: [Facts, {Limen.LiveView, instance: :limen_live_test, policy: Policy}] do
        live "/signup", SignupLive
      end
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :limen

    @session [store: :cookie, key: "_limen_live", signing_salt: "limen-live"]

    socket "/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [:peer_data, :x_headers, :user_agent, :uri, session: @session]]

    plug Limen.Plug, instance: :limen_live_test, policy: :off
    plug Plug.Session, @session
    plug Router
  end
end
