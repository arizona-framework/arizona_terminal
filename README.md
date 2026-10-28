# arizona_terminal

An ANSI terminal render target for [Arizona](https://github.com/arizona-framework/arizona):
a live view rendered with `?terminal(...)`, served over a local TTY or SSH, with no HTTP
server.

## Installation

```erlang
{deps, [
    {arizona_terminal, {git, "https://github.com/arizona-framework/arizona_terminal.git", {branch, "main"}}}
]}.
```

Requires OTP 29 (the backend calls `io_ansi`). Include the header beside Arizona's:

```erlang
-include_lib("arizona/include/arizona_stateful.hrl").
-include_lib("arizona_terminal/include/arizona_terminal.hrl").
```

The header defines `?terminal` as `arizona_template:target(arizona_terminal, Elems)`:
the macro names its backend, and Arizona's parse transform compiles it with that
backend. An app that serves over SSH lists
`ssh` in its own `applications`; this package starts it lazily when the SSH transport
starts, so a TTY-only app never boots it.

## Overview

`?terminal(Elems)` renders a view to ANSI text instead of HTML or JSON. The backend
is `arizona_terminal` (an `arizona_renderer`), the sibling of `arizona_html` and
`arizona_json`. Its transport **repaints the whole frame** on every update
(`arizona_live:render_current/1`) rather than applying diff ops, so the backend
writes **no `az`/slot markers** -- the diff engine's ops are computed but ignored.

The frame is printed from the live process's **diffed snapshot** (the root's, with each
child view's current copy refreshed in), not from a fresh render of the template, so a
repaint runs no `mount/1` or `handle_update/3` and shows exactly the state the process
holds. It follows that a terminal sees what a web client sees: `az-nodiff` content
renders once, and a slot whose reads are not tracked freezes after its first render.
When the node can reload code (`arizona_reloader:enabled/0`) a hot reload remounts the view
in place (`arizona_terminal_session:handle_reload/1,2`): the session joins the reloader
topic at start, and on `{arizona_reloader, reload}` stops the live process, mounts a fresh one from
the connection's bindings (an SSH channel's current geometry) and repaints, so the view's
state resets as a browser page's does. A terminal client does not reconnect, so this is the
terminal's counterpart of the WebSocket close described under "Exit reason to close code".
Otherwise, edited template text appears once a slot depending on it changes.

Escaping is per-backend via the `c:arizona_renderer:escape/1` callback, selected by the
render target: HTML entity-escapes, terminal **control-char sanitizes** (strips C0
bytes except `\n`/`\t`, DEL, and the C1 controls, and replaces every byte outside
well-formed UTF-8 with U+FFFD, so the output is always valid UTF-8; this assumes a UTF-8
terminal, since an 8-bit one reads UTF-8 continuation bytes `80`-`9F` as C1 controls), JSON
emits a JSON string. JSON alone carries a value
differently on the wire: its client JSON-encodes each `d` value itself, so the
fingerprint payload takes the raw value from `c:arizona_renderer:wire_escape/1`
(`wire_attr/2` for a prop) while the zipped document keeps the JSON string.
So a dynamic value in a `?terminal` view cannot inject ANSI/OSC escape sequences into
another user's terminal (the terminal analog of XSS). The `?raw` opt-out bypasses it --
never wrap untrusted data in `?raw` in a `?terminal` template.

## Elements

| Tag             | Emits                                                          |
| --------------- | -------------------------------------------------------------- |
| `line`          | its content, a style reset, then a newline -- one terminal row |
| `col` / `row`   | its content, then a style reset -- a transparent container     |
| `text` / `span` | its content, then a style reset -- inline, no newline          |
| `br`            | a void element emitting a newline                              |

Only `line` (newline) and `br` (void newline) affect layout; `col`, `row`, `text`,
and `span` are behaviorally identical (open emits nothing, close emits a style
reset) -- the names are documentary. So **vertical layout is a `col` of `line`s**,
and horizontal is several `text`/`span` inside one `line`.

## Styling

Set styles with **bare-atom boolean attributes** mapped to `io_ansi` escapes:
`bold`, `dim`, `italic`, `underline`, `inverse`, and the colours
`black`/`red`/`green`/`yellow`/`blue`/`magenta`/`cyan`/`white` plus their `light_*`
variants. For anything the atoms don't cover, use a valued attribute: `{sgr, Escape}`
(a raw escape, verbatim), `{fg, Index}` / `{bg, Index}` (256-colour palette by
index). Styles **do not inherit** across containers (every element resets on close),
so put the style on the `line`/`text` that needs it. An unknown style atom, an
unknown valued attribute, a dynamic attribute value, or an event-command attribute
is **rejected at compile time**, not silently dropped. So is an unknown **element**:
the tag table above is the whole vocabulary, so a tag outside it is a typo rather than
an extension point, and accepting it as a transparent container swallowed the author's
intent silently (`{'BR', [], []}` emitted a style reset instead of a newline). Terminal
tag names are **case-sensitive** -- the vocabulary is Arizona's own, not HTML's, so
`Line` is not `line`. (This is the opposite of the `?html` target, whose tag
*classification* folds case because the browser's parser does.)

```erlang
render(Bindings) ->
    ?terminal(
        {col, [], [
            {line, [bold, green], [~"== Title =="]},
            {line, [], [~"plain ", {span, [yellow], [~"highlighted"]}, ~" tail"]},
            {line, [{fg, ~"208"}], [~"256-colour orange"]}
        ]}
    ).
```

**Conditional rows:** a control-flow expression (`case`/`if`/`begin`/`receive`/`try`/
`maybe`) returning a bare element tuple from a tail in a content slot is compiled into a
nested template (inheriting the enclosing target), just as a literal `?html`/`?terminal`
there would be -- no wrap needed:

```erlang
{col, [], [
    case ?get(mode) of
        warn -> {line, [yellow], [~"check your input"]};
        _ -> <<>>
    end
]}
```

For 0-or-N rows, `?each` over a list still applies:

```erlang
?each(fun(Msg) -> {line, [yellow], [Msg]} end, status_rows(?get(mode)))
```

## Running a `?terminal` view

`arizona_terminal_session` is the transport-agnostic core: it mounts the view, turns
input into `arizona_live:handle_event/4` calls, and repaints. It is parameterized by
a **driver** (`arizona_terminal_driver` -- the key map, paint model, and screen
setup/teardown, with defaults in `arizona_terminal_default_driver` that the session
falls back to per callback) and an output fun. Two transports drive it:
`arizona_terminal_tty` (a local raw-mode TTY) and `arizona_terminal_ssh` (a view served over
SSH). `arizona_terminal_io:keys/1` decodes a raw input read into idiomatic keys
(char codes, atoms like `up`/`enter`, `{ctrl, _}` / `{alt, _}`) for drivers to match
on.

Every `paint/3` decides `continue` or `stop`, the **initial** paint included: a driver
that stops on the first frame gets its teardown emitted and the live view reaped, and
`arizona_terminal_session:start/5` answers `quit` instead of handing back a session.
The SSH transport serves one view per channel -- a second `shell` request is refused
rather than mounting a second view over the first, `exec` is refused (this shell is
interactive only), and input or a resize arriving before the `shell` request is
dropped or folded into the mount geometry rather than reaching a session that does not
exist yet.

A view drives the terminal back with **effects** from `arizona_terminal_effect` (the
`?terminal` analog of `arizona_js` / `arizona_android`): `quit/0` stops the session,
`set_title/1` sets the terminal title, `bell/0` rings it. The default driver's
`paint/3` interprets these and repaints in place (no full-screen clear, so no
flicker). Effects tied to a specific paint model (e.g. a scrolling log above a pinned
block) stay the concern of a custom driver, like the demo's.

## Demos

`make term-demo` runs a live view in the current terminal (needs a real TTY; press `q`
to quit). `make ssh-server` serves the same view over SSH; connect with
`make ssh-client` from another shell.

## License

Apache-2.0, see [LICENSE.md](LICENSE.md).
