-module(arizona_terminal_template_SUITE).
-moduledoc false.
-include_lib("stdlib/include/assert.hrl").

%% How the parse transform compiles `?terminal`: the backend's markers, escaping,
%% styles and the vocabulary it rejects at compile time. Each source declares the
%% target the way arizona_terminal.hrl does.

-export([all/0]).
-export([groups/0]).
-export([terminal_target_marked/1]).
-export([terminal_value_marked_for_escape/1]).
-export([terminal_sanitizes_control_chars/1]).
-export([terminal_renders_styled_ansi/1]).
-export([terminal_custom_sgr_attr/1]).
-export([terminal_fg_attr/1]).
-export([terminal_unknown_style_rejected/1]).
-export([terminal_unknown_false_style_rejected/1]).
-export([terminal_unknown_attr_rejected/1]).
-export([terminal_unknown_tag_rejected/1]).
-export([terminal_known_tags_accepted/1]).
-export([terminal_event_command_rejected/1]).
-export([terminal_dynamic_attr_rejected/1]).
-export([terminal_each_renders/1]).

all() ->
    [{group, terminal}].

groups() ->
    [
        {terminal, [parallel], [
            terminal_target_marked,
            terminal_value_marked_for_escape,
            terminal_sanitizes_control_chars,
            terminal_renders_styled_ansi,
            terminal_custom_sgr_attr,
            terminal_fg_attr,
            terminal_unknown_style_rejected,
            terminal_unknown_false_style_rejected,
            terminal_unknown_attr_rejected,
            terminal_unknown_tag_rejected,
            terminal_known_tags_accepted,
            terminal_event_command_rejected,
            terminal_dynamic_attr_rejected,
            terminal_each_renders
        ]}
    ].

terminal_target_marked(Config) when is_list(Config) ->
    %% A ?terminal template carries `backend => arizona_terminal`.
    Mod = compile_module(
        "-module(pt_term_marked). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {line, [green], [arizona_template:get(msg, Bindings)]}"
        "    ). "
    ),
    T = Mod:render(#{msg => ~"hi"}),
    ?assertEqual(arizona_terminal, maps:get(backend, T)).

%% A `?terminal` value interpolation is now escape-marked (`{esc, Fun}`), like
%% the HTML backend, so the terminal escaper (control-char sanitizer) runs on it
%% at the render boundary. Before, terminal values were emitted bare.
terminal_value_marked_for_escape(Config) when is_list(Config) ->
    Mod = compile_module(
        "-module(pt_term_esc). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {col, [], [{line, [], [arizona_template:get(msg, Bindings)]}]}"
        "    ). "
    ),
    T = Mod:render(#{msg => ~"hi"}),
    ?assertMatch([{_Az, {esc, _Fun}, {pt_term_esc, 1}}], maps:get(d, T)),
    [{_, {esc, Fun}, _}] = maps:get(d, T),
    ?assertEqual(~"hi", Fun()).

%% A `?terminal` dynamic value carrying control bytes is sanitized at render, so
%% it cannot inject ANSI/OSC escape sequences into the terminal (the terminal
%% analog of XSS). ESC and BEL from the value are stripped -- neutralizing the
%% OSC-52 clipboard write -- while printable bytes and UTF-8 survive. The line's
%% own ANSI (CSI `\e[`) is framework static, not a dynamic value, so it is intact.
terminal_sanitizes_control_chars(Config) when is_list(Config) ->
    Mod = compile_module(
        "-module(pt_term_sanitize). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {col, [], [{line, [], [arizona_template:get(msg, Bindings)]}]}"
        "    ). "
    ),
    %% 'a' ESC ]52;c;<base64> BEL 'b' -- an OSC-52 clipboard-write injection.
    %% (Erlang has no `\a` escape, so BEL 0x07 is written as an explicit byte.)
    {Output, _Snap} = arizona_render:render(Mod:render(#{msg => <<"a\e]52;c;ZXZpbA==", 7, "b">>})),
    Bin = iolist_to_binary(Output),
    ?assertEqual(nomatch, binary:match(Bin, ~"\e]")),
    ?assertEqual(nomatch, binary:match(Bin, <<7>>)),
    ?assertNotEqual(nomatch, binary:match(Bin, ~"]52;c;ZXZpbA==")),
    %% UTF-8 multi-byte content is preserved byte-intact.
    {Output2, _} = arizona_render:render(Mod:render(#{msg => <<"café"/utf8>>})),
    ?assertNotEqual(nomatch, binary:match(iolist_to_binary(Output2), <<"café"/utf8>>)).

terminal_renders_styled_ansi(Config) when is_list(Config) ->
    Mod = compile_module(
        "-module(pt_term_styled). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {col, [], ["
        "            {line, [green], [arizona_template:get(msg, Bindings)]}"
        "        ]}"
        "    ). "
    ),
    T = Mod:render(#{msg => ~"hi"}),
    {Output, _Snap} = arizona_render:render(T),
    %% green SGR (\e[32m), the dynamic text, then the line's reset+newline
    %% (\e[0m\n) followed by the col's reset (\e[0m).
    ?assertEqual(~"\e[32mhi\e[0m\n\e[0m", iolist_to_binary(Output)).

terminal_custom_sgr_attr(Config) when is_list(Config) ->
    %% {sgr, Escape} emits a raw escape verbatim (escape hatch for custom codes).
    Mod = compile_module(
        "-module(pt_term_sgr). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [{sgr, <<\"\\e[1m\">>}], [arizona_template:get(msg, Bindings)]}"
        "    ). "
    ),
    T = Mod:render(#{msg => ~"x"}),
    {Output, _Snap} = arizona_render:render(T),
    ?assertEqual(~"\e[1mx\e[0m", iolist_to_binary(Output)).

terminal_fg_attr(Config) when is_list(Config) ->
    %% {fg, Index} selects a 256-colour palette entry.
    Mod = compile_module(
        "-module(pt_term_fg). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [{fg, <<\"208\">>}], [arizona_template:get(msg, Bindings)]}"
        "    ). "
    ),
    T = Mod:render(#{msg => ~"x"}),
    {Output, _Snap} = arizona_render:render(T),
    ?assertEqual(~"\e[38;5;208mx\e[0m", iolist_to_binary(Output)).

terminal_unknown_style_rejected(Config) when is_list(Config) ->
    assert_parse_error(
        "-module(pt_term_bad_style). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [grween], [arizona_template:get(x, Bindings)]}"
        "    ). ",
        fun
            ({render_reject, _}) -> true;
            (_) -> false
        end
    ).

%% A static `false` emits nothing, but a misspelled style is still a typo: it is
%% rejected like the `true` form, not dropped silently.
terminal_unknown_false_style_rejected(Config) when is_list(Config) ->
    assert_parse_error(
        "-module(pt_term_bad_false_style). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [{bolld, false}], [arizona_template:get(x, Bindings)]}"
        "    ). ",
        fun
            ({render_reject, _}) -> true;
            (_) -> false
        end
    ).

terminal_unknown_attr_rejected(Config) when is_list(Config) ->
    assert_parse_error(
        "-module(pt_term_bad_attr). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [{class, <<\"box\">>}], [arizona_template:get(x, Bindings)]}"
        "    ). ",
        fun
            ({render_reject, _}) -> true;
            (_) -> false
        end
    ).

%% The terminal backend rejects an unknown attribute name loudly but used to accept
%% ANY tag as a transparent container, so a typo'd tag silently lost its meaning:
%% `{'BR', [], []}` emitted a style reset instead of a newline, and `{'Line', ...}`
%% dropped the newline the author asked for. The vocabulary is closed -- reject an
%% unknown element the same way an unknown attribute is rejected.
terminal_unknown_tag_rejected(Config) when is_list(Config) ->
    Bad = [
        {"pt_term_bad_tag", "{'div', [], [arizona_template:get(x, Bindings)]}"},
        %% The exact silent-typo shapes: a terminal tag in the wrong case.
        {"pt_term_upper_br", "{'BR', [], []}"},
        {"pt_term_upper_line", "{'Line', [], [arizona_template:get(x, Bindings)]}"}
    ],
    lists:foreach(
        fun({Mod, Elem}) ->
            assert_parse_error(
                lists:flatten([
                    "-module(",
                    Mod,
                    "). -arizona_target({terminal, arizona_terminal}). ",
                    "-export([render/1]). render(Bindings) -> ",
                    "arizona_template:terminal({col, [], [",
                    Elem,
                    "]}). "
                ]),
                fun
                    ({render_reject, _}) -> true;
                    (_) -> false
                end
            )
        end,
        Bad
    ).

%% Control: every documented tag still compiles and keeps its emission -- `line`
%% resets and breaks, `br` breaks, the rest are transparent containers.
terminal_known_tags_accepted(Config) when is_list(Config) ->
    Mod = compile_module(
        "-module(pt_term_tags_ok). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal({col, [], ["
        "        {row, [], [{text, [], [<<\"a\">>]}, {span, [], [<<\"b\">>]}]}, "
        "        {line, [], [<<\"c\">>]}, "
        "        {br, [], []}"
        "    ]}). "
    ),
    {Output, _Snap} = arizona_render:render(Mod:render(#{})),
    ?assertEqual(~"a\e[0mb\e[0m\e[0mc\e[0m\n\n\e[0m", iolist_to_binary(Output)).

terminal_event_command_rejected(Config) when is_list(Config) ->
    assert_parse_error(
        "-module(pt_term_bad_cmd). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [{az_click, arizona_js:push_event(<<\"go\">>)}], "
        "               [arizona_template:get(x, Bindings)]}"
        "    ). ",
        fun
            ({render_reject, _}) -> true;
            (_) -> false
        end
    ).

terminal_dynamic_attr_rejected(Config) when is_list(Config) ->
    assert_parse_error(
        "-module(pt_term_dyn_attr). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal("
        "        {text, [{fg, arizona_template:get(color, Bindings)}], "
        "               [arizona_template:get(x, Bindings)]}"
        "    ). ",
        fun
            ({render_reject, _}) -> true;
            (_) -> false
        end
    ).

terminal_each_renders(Config) when is_list(Config) ->
    %% ?each inside ?terminal compiles each item with the terminal backend and
    %% renders one ANSI line per list element.
    Mod = compile_module(
        "-module(pt_term_each). -arizona_target({terminal, arizona_terminal}). "
        "-export([render/1]). "
        "render(Bindings) -> "
        "    arizona_template:terminal({col, [], ["
        "        arizona_template:each("
        "            fun(Item) -> {line, [], [Item]} end,"
        "            arizona_template:get(items, Bindings))"
        "    ]}). "
    ),
    T = Mod:render(#{items => [~"a", ~"b"]}),
    {Output, _Snap} = arizona_render:render(T),
    Bin = iolist_to_binary(Output),
    ?assertNotEqual(nomatch, binary:match(Bin, ~"a\e[0m\n")),
    ?assertNotEqual(nomatch, binary:match(Bin, ~"b\e[0m\n")).

compile_module(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    ParsedForms = [
        begin
            {ok, F} = erl_parse:parse_form(Toks),
            F
        end
     || Toks <- split_forms(Tokens)
    ],
    TransformedForms = arizona_parse_transform:parse_transform(ParsedForms, []),
    {ok, Mod, Bin} = compile:forms(TransformedForms, [return_errors]),
    {module, Mod} = code:load_binary(Mod, "", Bin),
    Mod.

assert_parse_error(Source, MatchFun) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    ParsedForms = [
        begin
            {ok, F} = erl_parse:parse_form(Toks),
            F
        end
     || Toks <- split_forms(Tokens)
    ],
    case arizona_parse_transform:parse_transform(ParsedForms, []) of
        {error, [{_File, [{_Line, arizona_parse_transform, Reason}]}], []} ->
            ?assert(MatchFun(Reason));
        _ ->
            error(expected_parse_error)
    end.

split_forms(Tokens) ->
    split_forms(Tokens, [], []).

split_forms([], [], Acc) ->
    lists:reverse(Acc);
split_forms([], Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
split_forms([{dot, _} = Dot | Rest], Current, Acc) ->
    split_forms(Rest, [], [lists:reverse([Dot | Current]) | Acc]);
split_forms([Token | Rest], Current, Acc) ->
    split_forms(Rest, [Token | Current], Acc).
