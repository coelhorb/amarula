#!/usr/bin/env elixir

# Report dependencies whose newest published version our own mix.exs requirement
# forbids — the "should we broaden this bound?" signal.
#
# Usage:
#   mix run scripts/check_dep_headroom.exs          # report; exit 1 if anything is blocked
#   mix run scripts/check_dep_headroom.exs --warn    # report; always exit 0
#
# Why this exists: we deliberately pin 0.x deps inside their minor (`~> 0.5.1`),
# because for 0.x packages the minor is upstream's breaking/feature channel and
# this is a library — consumers resolve our constraints against their own tree
# and we cannot test what they land on. The cost of that choice is that a fix
# published as a minor bump sits behind our bound, which is exactly how the
# protobuf CVE reached consumers (fix in 0.16.1, our cap `< 0.16.0`).
#
# A tight pin is only safe if it is not allowed to go stale silently. This is the
# thing that refuses to let it: run weekly from
# .github/workflows/deps-freshness.yml. It is a maintainer signal, not a
# dependency check consumers run.
#
# Deliberately built on `mix hex.outdated --json` rather than parsing the table —
# the JSON carries a per-requirement `up_to_date` flag, which is what separates
# "the lock is behind, deps.update takes it" from "our mix.exs forbids it".

warn_only? = "--warn" in System.argv()

# `hex.outdated` exits 1 whenever ANY dependency is behind the registry — dev
# tooling included — so its status is not the signal we want and must not be
# matched on. We re-derive a narrower verdict from the JSON below and own the
# exit code ourselves.
{json, _status} = System.cmd("mix", ["hex.outdated", "--json"])

packages = Jason.decode!(json)

# A "blocked" package is one where a newer version exists AND at least one of our
# own mix.exs requirements refuses it. `only: ""` narrows to runtime deps: a new
# credo major is maintenance noise, not something that reaches a consumer.
blocked =
  for %{"only" => "", "outdated" => true} = pkg <- packages,
      req <- pkg["requirements"],
      req["source"] == "mix.exs",
      req["up_to_date"] == false do
    %{
      package: pkg["package"],
      locked: pkg["lock_version"],
      latest: pkg["latest_version"],
      requirement: req["requirement"]
    }
  end

case blocked do
  [] ->
    IO.puts("""
    Every runtime dependency's newest published version is reachable within our
    mix.exs bounds. No broadening needed.
    """)

  blocked ->
    IO.puts("""

    #{length(blocked)} runtime dependency(ies) have a newer version that our own
    mix.exs requirement forbids. Each needs a deliberate, tested bound bump:
    """)

    for %{package: p, locked: l, latest: v, requirement: r} <- blocked do
      IO.puts("  #{p}: locked #{l}, published #{v} — our bound #{inspect(r)} caps it out")
    end

    IO.puts("""

    To broaden one: widen the bound in mix.exs, then run
      mix deps.update <pkg> && mix test && mix hex.audit
    and commit the reviewed result. Do not widen without running the suite —
    for a 0.x dep the minor bump may be breaking.
    """)

    unless warn_only?, do: System.halt(1)
end
