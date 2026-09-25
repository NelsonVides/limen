if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Limen.Dashboard do
    @moduledoc """
    A Phoenix LiveDashboard page for a Limen instance.

        live_dashboard "/dashboard",
          additional_pages: [limen: {Limen.Dashboard, otp_app: :my_app}]

    It shows decision and challenge rates, active prefixes, the busiest
    prefixes and JA4 fingerprints of the last minute, active bans and the
    latest sampled decisions of the instance on the node selected in the
    dashboard. Figures are node-local; pick another node to see its view.

    Takes the instance as `Limen.Plug` does, with `:instance` or `:otp_app`.
    Add one page per instance to watch several.
    """

    use Phoenix.LiveDashboard.PageBuilder, refresher?: true

    alias Limen.Dashboard.Data

    @rows 20

    @impl true
    def init(opts), do: {:ok, %{instance: Limen.Instance.name!(opts)}}

    @impl true
    def menu_link(%{instance: instance}, _capabilities), do: {:ok, "Limen (#{instance})"}

    @impl true
    def mount(_params, %{instance: instance}, socket) do
      {:ok, refresh(assign(socket, instance: instance))}
    end

    @impl true
    def handle_refresh(socket), do: {:noreply, refresh(socket)}

    defp refresh(socket) do
      snapshot = fetch(socket.assigns.page.node, :snapshot, [socket.assigns.instance])
      rates = Data.rates(socket.assigns[:snapshot], snapshot)
      assign(socket, snapshot: snapshot, rates: rates)
    end

    defp fetch(node, function, args) when node == node(), do: apply(Data, function, args)
    defp fetch(node, function, args), do: :erpc.call(node, Data, function, args, 5_000)

    @impl true
    def render(assigns) do
      ~H"""
      <.row>
        <:col>
          <.fields_card title="Decisions per second" fields={decision_fields(@rates)} />
        </:col>
        <:col>
          <.fields_card title="Challenges per second" fields={challenge_fields(@rates)} />
        </:col>
        <:col>
          <.fields_card title="State" fields={state_fields(@snapshot)} />
        </:col>
      </.row>
      <.live_table
        id="limen-prefixes"
        dom_id="limen-prefixes"
        page={@page}
        title="Busiest prefixes, this minute"
        row_fetcher={&rows(&1, &2, @instance, :top_prefixes)}
        rows_name="prefixes"
        search={false}
        limit={false}
      >
        <:col field={:prefix} header="Prefix" />
        <:col field={:requests} header="Requests" text_align="right" sortable={:desc} />
      </.live_table>
      <.live_table
        id="limen-ja4"
        dom_id="limen-ja4"
        page={@page}
        title="Busiest JA4 fingerprints, this minute"
        row_fetcher={&rows(&1, &2, @instance, :top_ja4)}
        rows_name="fingerprints"
        search={false}
        limit={false}
      >
        <:col field={:ja4} header="JA4" />
        <:col field={:requests} header="Requests" text_align="right" sortable={:desc} />
      </.live_table>
      <.live_table
        id="limen-bans"
        dom_id="limen-bans"
        page={@page}
        title="Bans"
        row_fetcher={&rows(&1, &2, @instance, :bans)}
        rows_name="bans"
        search={false}
        limit={false}
      >
        <:col field={:prefix} header="Prefix" />
        <:col field={:reason} header="Reason" />
        <:col field={:origin} header="Origin" />
        <:col field={:mode} header="Mode" />
        <:col field={:expires_in} header="Expires in (s)" text_align="right" sortable={:asc} />
      </.live_table>
      <.live_table
        id="limen-recent"
        dom_id="limen-recent"
        page={@page}
        title="Recent sampled decisions"
        row_fetcher={&rows(&1, &2, @instance, :recent)}
        rows_name="decisions"
        search={false}
        limit={false}
      >
        <:col field={:action} header="Action" />
        <:col field={:enforced} header="Enforced" />
        <:col field={:stage} header="Stage" />
        <:col field={:score} header="Score" text_align="right" sortable={:desc} />
        <:col field={:prefix} header="Prefix" />
        <:col field={:path} header="Path" />
        <:col field={:rules} header="Rules" />
      </.live_table>
      """
    end

    # Several tables share the page, so none shows its own page-size selector.
    defp rows(params, node, instance, function) do
      rows = fetch(node, function, [instance, @rows])
      {sort(rows, params), length(rows)}
    end

    defp sort(rows, %{sort_by: sort_by, sort_dir: direction}) when is_atom(sort_by) do
      Enum.sort_by(rows, &Map.get(&1, sort_by), direction)
    end

    defp sort(rows, _params), do: rows

    defp decision_fields(rates) do
      [
        {"Allowed", rates.allow},
        {"Challenged", rates.challenge},
        {"Throttled", rates.throttle},
        {"Denied", rates.deny},
        {"Tarpitted", rates.tarpit},
        {"Pass fast path", rates.pass},
        {"Enforced", rates.enforced}
      ]
    end

    defp challenge_fields(rates) do
      [
        {"Issued", rates.challenge_issued},
        {"Solved", rates.challenge_solved},
        {"Failed", rates.challenge_failed},
        {"Bans added", rates.ban_added},
        {"Saturated table writes", rates.saturated}
      ]
    end

    defp state_fields(snapshot) do
      [
        {"Mode", snapshot.mode},
        {"Active prefixes (1-2 min)", snapshot.active_prefixes},
        {"Active bans", snapshot.bans},
        {"Requests held in tarpit", snapshot.tarpitted},
        {"State memory", "#{Float.round(snapshot.memory / 1_048_576, 1)} MiB"}
      ]
    end
  end
end
