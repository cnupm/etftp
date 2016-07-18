-module(etftp_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    etftp:start_link().

stop(_State) ->
    etftp:stop().