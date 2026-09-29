if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Limen.Dashboard do
    @moduledoc """
    A Phoenix LiveDashboard page for a Limen instance.

        live_dashboard "/dashboard",
          additional_pages: [limen: {Limen.Dashboard, otp_app: :my_app}]

    It shows decision, challenge and trap rates, active prefixes, the busiest
    prefixes of the last minute, the JA4 fingerprints with the most clients,
    active bans and the latest sampled decisions of the instance on the node
    selected in the dashboard. Figures are node-local; pick another node to see its view.

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
          <.fields_card title="Challenges and traps per second" fields={challenge_fields(@rates)} />
        </:col>
        <:col>
          <.fields_card title="State" fields={state_fields(@snapshot)} />
        </:col>
      </.row>
      <.row>
        <:col>
          <.fields_card title="IP-to-ASN data" fields={asn_fields(@snapshot.asn)} />
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
        title="JA4 fingerprints with the most clients, this minute"
        row_fetcher={&rows(&1, &2, @instance, :top_ja4)}
        rows_name="fingerprints"
        search={false}
        limit={false}
      >
        <:col field={:ja4} header="JA4" />
        <:col field={:clients} header="Clients" text_align="right" sortable={:desc} />
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
        <:col field={:action} header="Action" />
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
        {"Sent to the maze", rates.maze},
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
        {"Trap hits", rates.trap_hit},
        {"Maze pages served", rates.maze_served},
        {"Maze requests refused", rates.maze_refused},
        {"Saturated table writes", rates.saturated}
      ]
    end

    defp state_fields(snapshot) do
      [
        {"Mode", snapshot.mode},
        {"Active prefixes (1-2 min)", snapshot.active_prefixes},
        {"Active bans", snapshot.bans},
        {"Requests held in tarpit", snapshot.tarpitted},
        {"Requests held in the maze", snapshot.in_maze},
        {"State memory", "#{Float.round(snapshot.memory / 1_048_576, 1)} MiB"}
      ]
    end

    defp asn_fields(%{ranges: nil} = asn), do: [{"Ranges", "none loaded"} | check_fields(asn)]

    defp asn_fields(asn) do
      [
        {"Ranges", asn.ranges},
        {"Memory", "#{Float.round(asn.bytes / 1_048_576, 1)} MiB"},
        {"Loaded", "#{ago(asn.loaded_at)} from #{source(asn.source)}"}
        | check_fields(asn)
      ]
    end

    defp check_fields(%{busy: true}), do: [{"Loader", "busy loading or checking"}]

    defp check_fields(asn) do
      [
        {"Last check", last_check(asn.last_check, asn.failures)},
        {"Next check", if(asn.next_check, do: from_now(asn.next_check), else: "never")}
      ]
    end

    defp last_check(nil, _failures), do: "none yet"

    defp last_check(%{at: at, result: result}, failures) do
      failed = if failures > 1, do: ", #{failures} failures in a row", else: ""
      "#{ago(at)}: #{outcome(result)}#{failed}"
    end

    defp outcome({kind, reason}), do: "#{kind} (#{inspect(reason)})"
    defp outcome(result), do: to_string(result)

    defp source({_kind, location}), do: location
    defp source(:rows), do: "rows"

    defp ago(at), do: "#{duration(System.system_time(:millisecond) - at)} ago"
    defp from_now(at), do: "in #{duration(at - System.system_time(:millisecond))}"

    defp duration(ms) when ms < 60_000, do: "#{max(div(ms, 1_000), 0)} s"
    defp duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"
    defp duration(ms) when ms < 172_800_000, do: "#{div(ms, 3_600_000)} h"
    defp duration(ms), do: "#{div(ms, 86_400_000)} days"
  end
end
