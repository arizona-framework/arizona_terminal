%% The `?terminal` (ANSI) render target. Include it beside arizona_stateful.hrl or
%% arizona_stateless.hrl: the macro names its backend, and the parse transform
%% compiles `?terminal(...)` with it.
-define(terminal(Elems), arizona_template:target(arizona_terminal, Elems)).
