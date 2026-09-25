# Honeypots and the maze

Challenges make automated clients pay for every identity they use. Honeypots
catch the clients that give themselves away by acting in ways people never
do: following links nobody can see, or filling in fields nobody is shown.
Clients caught that way are sent to the *maze*: endless, plausible pages,
sent slowly, whose links all lead deeper in. A scraper in the maze spends its
time and its crawl budget on pages worth nothing, and is never told it was
caught.

```
hidden link or form field ──► trap ──► prefix flagged (ban with action: :maze)
                                                 │
            every later request from the prefix ─┴──► maze page, dripped slowly
                                                              │
                                     links lead back into the trap ◄──┘
```

Like everything in Limen, traps run in dry-run mode first: they record what
they would have done and let requests through.

## Link traps

### 1. Pick trap paths

Choose one or more paths your application does not use, and that look like
something a scraper would want: a directory, an archive, an export.

```elixir
# config/runtime.exs
config :my_app, Limen,
  trap: [paths: ["/archive/directory"], ban: 86_400]
```

`Limen.Plug` answers requests under trap paths itself, before any route, so
the path never reaches your router. `:ban` is how long, in seconds, a client
that fell into a trap stays in the maze (a day by default). Trap paths cannot
be under Limen's challenge path (`/__limen`).

### 2. Keep well-behaved crawlers out

Search engines honour `robots.txt`. Disallow the trap paths so that they
never go there, whatever links they find. `Limen.Trap.robots/1` returns the
lines:

```elixir
# router.ex
get "/robots.txt", RobotsController, :show

# robots_controller.ex
def show(conn, _params) do
  text(conn, "User-agent: *\n" <> Limen.Trap.robots(:my_app))
end
```

If you serve a static `robots.txt`, add a `Disallow:` line per trap path to it
instead.

As a second line of defence, crawlers verified with forward-confirmed reverse
DNS (see `Limen.Signal.Fcrdns`) are never flagged, and neither are requests
claiming to be a known crawler while their verification is pending. The
decision still records that they requested a trap.

### 3. Hide a link to the trap

Add a link people never see, typically in the footer of your root layout:

```heex
<footer>
  ...
  {Limen.Trap.link(:my_app)}
</footer>
```

It renders something like:

```html
<a href="/archive/directory/office-opens" rel="nofollow" tabindex="-1"
   aria-hidden="true" style="position:absolute;left:-10000px;...">Office opens</a>
```

- The link is off screen, out of the tab order and hidden from assistive
  technologies, so people, including screen reader users, never reach it.
- `rel="nofollow"` keeps away crawlers that honour it.
- The URL and its text are drawn from the maze and derived from your secret:
  they look like any other page of your site and stay the same across
  requests and nodes.

Options:

- `class: "sr-only"`: hide the link with a class of your stylesheet instead
  of an inline `style`, for pages whose Content-Security-Policy forbids inline
  styles.
- `text: "Carrier directory"`: your own link text.
- `path: "/old"`: link into another trap path.

`Limen.Trap.href/2` returns just the URL, for your own markup. Outside Phoenix
templates, `link/2` returns `{:safe, iodata}`: use the iodata.

You may want to render the link only for visitors who are not signed in:
signed-in users are known to you already.

### What happens on a hit

The request is settled at the `:trap` stage. In enforce mode:

1. the decision records the trap and is emitted and sampled like any other;
2. the client prefix is banned with `action: :maze`, `origin: :trap`;
3. the client gets a maze page instead of a response from your application,
   and so does every later `GET` request from that prefix, on any path, for
   `:ban` seconds. Other methods get a plain `403`.

```
maze(ban: 86400) (enforced) at stage trap, score 0
  prefix: 203.0.113.9/32
  client_ip: 203.0.113.9
  user_agent: python-requests/2.32.3
  via_proxy: false
  trap trap when requested a trap path [trap = "/archive/directory", path = "/archive/directory/regional-reports"]
  signal fcrdns = :not_claimed
```

A client already banned with the default `:deny` action that falls into a
trap is escalated to the maze. A client already in the maze stays there, at
the `:ban` stage.

### Precautions

- **Prefetching.** Browsers do not prefetch ordinary links, but pages using
  [speculation rules](https://developer.chrome.com/docs/web-platform/prerender-pages)
  can ask them to. Exclude trap paths from any rule matching all links
  (`"where": {"not": {"href_matches": "/archive/directory/*"}}`), and never
  list them in sitemaps.
- **Link-prefetching extensions** and aggressive security scanners can follow
  hidden links on behalf of a person. They are rare; keep `:ban` moderate so
  a mistake heals by itself, and watch the trap hits in the decision log.
- **Shared addresses.** A ban applies to a whole prefix (see `:ipv4_prefix`
  and `:ipv6_prefix`). Behind carrier-grade NAT, a scraper caught on an IPv4
  address sends everyone sharing it to the maze for `:ban` seconds.
  `Limen.unban/2` lifts it.

## Form traps

Scripts filling in forms fill in every field they find, and submit as fast as
they can. `Limen.Trap.form_fields/2` renders two hidden fields to catch both:

- a *decoy* text field (`website` by default, see `:form_field`), off screen,
  out of the tab order, hidden from assistive technologies and with
  `autocomplete="off"`;
- a signed timestamp of when the form was rendered.

`Limen.Trap.check_form/3` then finds the tells:

| Tell | Match | Meaning |
|---|---|---|
| The decoy field is filled in | `:form_decoy` | a script filled every field |
| Submitted sooner than `:min_fill_time` (3 s) | `:form_too_fast` | nobody reads and types that fast |
| The timestamp is missing or forged | `:form_token` | the form was never loaded, or was tampered with |

The timestamp is checked on whichever node receives the submission, so keep
node clocks in sync (NTP), as cluster bans need anyway.

Any tell traps the submission, flags the prefix for the maze, and returns
`{:trapped, decision}`; answer it as if it had worked, so the script learns
nothing. Otherwise it returns `{:ok, decision}`. Every check is a decision at
the `:trap` stage.

### In a controller

```heex
<.form for={@form} action={~p"/signup"}>
  {Limen.Trap.form_fields(:my_app)}
  <.input field={@form[:email]} type="email" label="Email" />
  <.button>Sign up</.button>
</.form>
```

```elixir
def create(conn, params) do
  case Limen.Trap.check_form(conn, params) do
    {:ok, _decision} ->
      create_account(conn, params["user"])

    {:trapped, _decision} ->
      # Exactly what a successful signup shows, without doing anything.
      redirect(conn, to: ~p"/signup/check-your-email")
  end
end
```

The trap's fields are read from the top level of `params`, next to the form's
own. Without options, `check_form/3` uses the instance that gated the request;
pass `otp_app:` or `instance:` otherwise.

### In a LiveView

LiveView only exposes the client's address and headers while mounting, so
mount through the `Limen.LiveView` hook (see `Limen.Socket`), which keeps them
for later form checks:

```elixir
live_session :default, on_mount: {Limen.LiveView, otp_app: :my_app} do
  live "/signup", SignupLive
end
```

```elixir
def handle_event("save", params, socket) do
  case Limen.LiveView.check_form(socket, params, otp_app: :my_app) do
    {:ok, _decision} -> save(socket, params["user"])
    {:trapped, _decision} -> {:noreply, push_navigate(socket, to: ~p"/signup/check-your-email")}
  end
end
```

### Choosing the decoy

Pick a name scripts expect and people's browsers do not fill in on their
own: `website`, `url` or `company` work well. Avoid names browser autofill
recognises for your users' data, such as `email`, `name` or `phone`.

## Sending clients to the maze yourself

Traps are the usual way in, but not the only one.

From a policy, a `maze` rule settles the request like `deny` does, and
`decide` can pick the maze too:

```elixir
defmodule MyApp.BotPolicy do
  use Limen.Policy

  maze :spoofed_crawler, when: signal(:fcrdns) == :failed, ban: 86_400

  score :tool_user_agent, 30, when: signal(:ua_family) == :tool
  score :datacenter_asn, 30, when: signal(:asn_kind) == :hosting

  decide do
    score >= 80 -> {:maze, ban: 3_600}
    score >= 40 -> {:challenge, difficulty: difficulty_for(score)}
    true -> :allow
  end
end
```

Without `ban:`, only the current request goes to the maze. With it, the
prefix is flagged and stays in the maze.

By hand, ban with `action: :maze`:

```elixir
Limen.ban(:my_app, "203.0.113.9", 86_400, action: :maze, reason: :scraper)
```

### Maze or tarpit?

Both keep a client waiting at little cost to you, but tell it different
things:

- `{:tarpit, delay: ms}` stays silent for `ms`, then answers `403`. The client
  knows it was refused and only paid for asking. Each request is judged on its
  own and nobody is banned. Use it where refusing is fine but retries should
  be slow: login floods, credential stuffing, API abuse.
- The maze answers `200` and keeps sending bytes, so clients whose timeouts
  measure silence keep waiting, and every link it gives leads deeper. A person
  sent there sees nonsense instead of an error, so keep it for clients you are
  sure about: trap hits, spoofed crawlers.

## The maze

### What a maze page is

An article, a listing of entries or a directory table, with a title,
navigation, dates and related links, written by a Markov chain language
model. Every link leads under the first trap path, so following one is a
confession in itself. Pages carry `noindex, nofollow` in a meta tag and an
`x-robots-tag` header.

### Stable for your site, unpredictable elsewhere

A page's content is drawn from a random generator seeded with an HMAC of its
path, keyed with your secret. On your site the same URL always gives the same
page, so a scraper comparing two fetches learns nothing; another site gives
different pages, and nobody can predict them without the secret. With
`drift: :daily` or `:weekly`, pages change at that pace, like a site being
edited. Rotating `:secret_key` changes every page.

How a page is delivered is random on every request: where it is cut into
chunks, how long each pause lasts, how long the response takes.

### Writing in your site's voice

Limen's bundled corpus is neutral prose from an imaginary organisation's
website. Give the model your own text as well, so the maze reads like your
site:

```elixir
config :my_app, Limen,
  maze: [corpus: [Application.app_dir(:my_app, "priv/maze/corpus.txt")]]
```

A corpus is plain text: sentences, one or more per line, `#` for comments.
Product descriptions, help pages and articles work well; a few hundred
sentences are plenty. Add `bundled_corpus: false` to use your text alone. The
model is built once, when the instance starts. Only use text you are happy
to have scraped: it is what the maze recombines.

### Slow by design

Rendering a page takes around 150 microseconds. The rest of a maze response
is spent asleep: the request process sends a chunk of `:chunk` bytes, sleeps
for `:delay`, and sends the next, at low process priority, until the page is
sent or `:max_duration` has passed, in which case the rest goes out at once
so the client finds the links that lead deeper. A client that disconnects
ends it immediately.

Each response held in the maze costs one process and a few kilobytes. At most
`:max_concurrent` are held at once; beyond that, clients get an immediate
`429`. Nothing on the way calls a process or sends a message.

| Option | Default | |
|---|---|---|
| `:max_concurrent` | `200` | responses held at once |
| `:max_duration` | `60_000` | milliseconds a response may take |
| `:delay` | `{1_000, 5_000}` | milliseconds between chunks |
| `:chunk` | `{64, 512}` | bytes per chunk |
| `:paragraphs` | `{4, 10}` | paragraphs per article |
| `:links` | `{4, 10}` | links in navigation and related lists |

Keep `:max_duration` below your proxy's read timeout (60 seconds for nginx
by default), or the proxy cuts responses short.

## Dry-run

In dry-run mode, traps behave exactly the same except for the final action:

- trap hits and form checks produce their decisions, with `enforced: false`;
- the flag is recorded as a dry-run ban, reported on later requests and never
  enforced, not even on routes that enforce;
- requests under trap paths continue to your application (which will usually
  answer `404`), and `check_form/3` returns `{:ok, decision}`;
- nobody is ever sent to the maze.

Deploy traps in dry-run, look at who falls in, then enforce.

## Watching

- Decisions at the `:trap` stage, and decisions whose action is `:maze`, in
  the decision log and the `[:limen, :decision]` telemetry event.
- `[:limen, :maze, :served]` telemetry: duration, bytes and chunks of each
  maze response, and whether it completed, hit the deadline or the client
  left.
- `[:limen, :ban, :added]`, whose metadata carries the `:action`.
- The LiveDashboard page: trap hits, maze pages served and refused, and
  responses currently held in the maze.

## Testing

In your application's tests, keep maze responses instant and forms
immediate:

```elixir
config :my_app, Limen,
  trap: [paths: ["/archive/directory"], min_fill_time: 0],
  maze: [delay: {0, 0}]
```

`Plug.Test` collects chunked responses, so `conn.resp_body` holds the whole
maze page.
