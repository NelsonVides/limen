# Instances flush their decision logs when they stop; only the tests that
# check logging want to see that.
Logger.configure(level: :warning)

ExUnit.start(exclude: [:node, :distributed, :browser])
