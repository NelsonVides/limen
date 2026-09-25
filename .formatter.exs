dsl = [allow: 2, deny: 2, score: 3, limit: 2, decide: 1]

# Phoenix macros used by the single-file examples, which cannot import_deps.
examples = [get: 3, live: 2, live: 3, live_session: 3, socket: 3, live_dashboard: 2]

[
  import_deps: [:plug, :stream_data],
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test,bench,examples}/**/*.{ex,exs}"],
  locals_without_parens: dsl ++ examples,
  export: [locals_without_parens: dsl]
]
