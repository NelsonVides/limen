defmodule Limen.Test.DashboardApp do
  @moduledoc """
  A minimal Phoenix application mounting the LiveDashboard with Limen's page
  for the `#{inspect(:limen_dashboard_test)}` instance.
  """

  @doc """
  The instance the dashboard page shows.
  """
  def instance, do: :limen_dashboard_test

  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    import Phoenix.LiveDashboard.Router

    pipeline :browser do
      plug :fetch_session
    end

    scope "/" do
      pipe_through(:browser)

      live_dashboard "/dashboard",
        additional_pages: [limen: {Limen.Dashboard, instance: :limen_dashboard_test}]
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :limen

    @session [store: :cookie, key: "_limen_test", signing_salt: "limen-test"]

    socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

    plug Plug.Session, @session
    plug Router
  end
end
