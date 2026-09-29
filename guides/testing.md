# Testing

Your application's tests run through Limen like any request does. This
guide sets it up so that most tests never notice it, and the tests about
Limen can check exactly what it does, concurrently.

## Configure the test instance

Your supervision tree starts the instance in tests too. Configure it in
`config/test.exs`:

```elixir
config :my_app, Limen,
  mode: :dry_run,
  secret_key: String.duplicate("test", 8),
  trap: [min_fill_time: 0],
  maze: [delay: {0, 0}, max_duration: 100]
```

- **`mode: :dry_run`**: test requests carry no user agent and none of the
  headers browsers send, so Limen scores them as automated. In dry-run mode
  it still evaluates and records every one of them, and refuses none.
- **`min_fill_time: 0`**: tests submit forms microseconds after rendering
  them, which a form trap would take for a script.
- **`maze: [delay: {0, 0}]`**: maze responses are sent at once. `Plug.Test`
  collects chunked responses, so `conn.resp_body` holds the whole page.
- **`secret_key`**: a fixed key keeps tokens valid across the test run and
  avoids the warning about generating one.

## Enforce one request at a time

The tests about Limen enforce it for their own requests only, with
`Limen.Test.put_mode/2`, and give each test a client of its own with
`Limen.Test.put_client_ip/2` and `Limen.Test.unique_ip/0`, so that one
test's bans and counters are not another's. They can then run with
`async: true`:

```elixir
defmodule MyAppWeb.BotGateTest do
  use MyAppWeb.ConnCase, async: true

  setup %{conn: conn} do
    %{conn: Limen.Test.put_client_ip(conn, Limen.Test.unique_ip())}
  end

  test "a client without a user agent is challenged", %{conn: conn} do
    conn = conn |> Limen.Test.put_mode(:enforce) |> get(~p"/")

    assert html_response(conn, 403) =~ "Checking your browser"
    assert %Limen.Decision{action: :challenge} = Limen.decision(conn)
  end

  test "signed-in users are trusted", %{conn: conn} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> Limen.Test.put_mode(:enforce)
      |> get(~p"/")

    assert %Limen.Decision{stage: :trust} = Limen.decision(conn)
  end
end
```

`Limen.decision/1` returns the decision for a request, and
`Limen.Decision.explain/1` shows why it was made, which makes a failing
assertion easy to read. `Limen.banned/2` tells whether a trap flagged the
client.

A request's own mode wins over every other: the instance's, the plug's,
the route's and the policy's. Changing the instance itself, with
`Limen.set_mode/2` or `Limen.update_config/3`, changes it for every test
running at the time, so keep that to tests with `async: false`, and set
it back in `on_exit/1`.

## LiveView

`Phoenix.LiveViewTest` connects the LiveView's socket with the request of
the test, but reports the test adapter's own address (`127.0.0.1`) as the
socket's peer, not the `remote_ip` the request was given.
`Limen.Test.put_client_ip/2` sets both, so the socket check sees the client
the HTTP gate saw.

In enforce mode the socket check wants the token the page embeds.
`Limen.Test.put_socket_token/2` adds it to the connect parameters, as
`app.js` would, without rendering the page first:

```elixir
test "a scripted signup is trapped", %{conn: conn} do
  conn =
    conn
    |> put_req_header("user-agent", "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0")
    |> Limen.Test.put_mode(:enforce)
    |> Limen.Test.put_socket_token(otp_app: :my_app)

  {:ok, view, _html} = live(conn, ~p"/signup")

  view
  |> form("#signup", user: %{email: "bot@example.com"}, website: "http://spam.example")
  |> render_submit()

  assert %{action: :maze, origin: :trap} = Limen.banned(:my_app, conn.remote_ip)
end
```

The request's mode applies to the socket check and to
`Limen.LiveView.check_form/3` too.

## Policies on their own

To test a policy without your application, start an instance just for the
test; it shares nothing with any other, and needs no care about
concurrency:

```elixir
setup do
  start_supervised!({Limen, name: :policy_test, config: [mode: :enforce]})
  :ok
end

test "curl is challenged" do
  opts = Limen.Plug.init(instance: :policy_test, policy: MyApp.BotPolicy)
  conn = conn(:get, "/") |> put_req_header("user-agent", "curl/8.5.0")

  assert %Limen.Decision{action: :challenge} = Limen.decision(Limen.Plug.call(conn, opts))
end
```

`Limen.Policy.evaluate/2` runs a policy's rules on a `Limen.Context` you
build yourself, for the rules alone:

```elixir
ctx = %Limen.Context{signals: %{ua_family: :tool}}
assert %{score: 30} = Limen.Policy.evaluate(MyApp.BotPolicy, ctx)
```
