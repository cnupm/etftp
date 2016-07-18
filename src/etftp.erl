-module(etftp).
-behaviour(gen_server).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3, stop/0, start_link/0, req_process/1]).
-define(SERVER,?MODULE).

-record(client, {socket, host, port, % udp datagram info
                    transfer = none, % transfer mode (read for RRQ, write for WRQ)
                    name = "", % file name from initial RRQ/WRQ request
                    handle, % actual file handle (ref. to IoDevice)
                    tid % current chunk Transfer ID
}).

%% behaviour callbacks
init(_Args) ->
    ets:new(?MODULE, [public, named_table]),
    {ok, Port} = application:get_env(etftp_app, port),
    {ok, Socket} = gen_udp:open(Port, [binary, {active, true}]),
    {ok, #client{socket = Socket}}.

terminate(Reason, State) ->
    io:format("terminating by ~p with state ~p~n", [Reason, State]),
    gen_udp:close(State#client.socket),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).
stop() -> gen_server:call(?MODULE, stop).
handle_call(stop, _From, State) -> {stop, normal, State};
handle_call(_Request, _From, State) -> {stop, {error, unknown_call}, State}.
handle_cast(stop, State) -> {stop, {error, unknown_cast}, State}.



%%
%% Server process
%%
handle_info({udp, _Socket, Host, Port, Bin}, State) ->
    %io:format("handle_info with state ~p, data is ~p~n", [State, Bin]),
    <<Opcode:16, Rest/binary>> = Bin,
    Key = {Host, Port},

    case Opcode of
        %% RRQ/WRQ -> start client handler process
        1 -> handle_req(State#client{host=Host, port=Port}, Opcode, Rest);
        2 -> handle_req(State#client{host=Host, port=Port}, Opcode, Rest);
        3 -> %% DATA
            {_, Pid} = hd(ets:lookup(?MODULE, Key)),
            Pid ! {data, Rest};
        4 -> %% ACK
            {_, Pid} = hd(ets:lookup(?MODULE, Key)),
            Pid ! {ack, Rest};
        5 -> %% ERROR
            io:format("Transfer failed with error: ~p, handler key: ~p~n", [Rest, Key]);
        _ -> send_error_msg(State, 4, unknown_op)
    end,
    {noreply, State}.

%%
%% Client handler process initialization
%%
handle_req(S, Opcode, Data) ->
    [File, _Mode] = string:tokens(binary:bin_to_list(Data), [0]),
    Transfer = case Opcode of
        1 -> read;
        2 -> write
    end,
    spawn_link(?MODULE, req_process, [[{S#client.host, S#client.port}, S#client{transfer = Transfer, name = File, tid = 1}]]),
    S.

%%
%% Client process main loop
%%
req_process(Args) ->
    [Key, State] = Args,
    ets:insert(?MODULE, {Key, self()}),  %store (or overwrite) reference to self

    Handle = case file:open(State#client.name, [State#client.transfer, binary]) of
        {ok, File} -> File;
        {error, Msg} -> send_error_msg(State, 1, Msg), false
    end,

    case Handle of
        false -> io:format("Failed to process request - invalid file handle~n");
        _ -> req_loop(State#client{handle = Handle})
    end.

% client-server handshake (init read/write op)
req_loop(State) when State#client.tid == 1 ->
    NewState = case State#client.transfer of
        read -> send_file(State);
        write ->
            send(State, <<0,4, 0,0>>), %%ACK, TID = 0
            State#client{tid = State#client.tid + 1}
    end,
    req_loop(NewState); %now switch to main transfer loop (TID > 1)

% main transfer loop
req_loop(State) ->
    Timeout = application:get_env(etftp_app, timeout),
    receive
        {ack, _Data} -> % RRQ or ERROR data
            NewState = case State#client.transfer of
                read -> send_file(State);
                _ -> true
            end,
            req_loop(NewState);
        {data, Data} -> %WRQ data
            <<_Tid:16, Content/binary>> = Data,
            NewState = recv_file(State, Content),
            req_loop(NewState);
        _ -> io:format("Unknown msg~n")
    after Timeout ->
        true
    end.

%%
%% WRQ transfer loop
%%
recv_file(State, Data) when byte_size(Data) > 0 ->
    Tid = State#client.tid - 1,
    
    case file:write(State#client.handle, Data) of
        ok -> send(State, <<0,4, Tid:16>>);
        {error, Reason} -> send_error_msg(State, 0, Reason)
    end,

    case byte_size(Data) < 512 of  %check if transfer was finished
        true -> file:close(State#client.handle);
        _ -> true
    end,
    
    State#client{tid = State#client.tid + 1};

recv_file(State, Data) when byte_size(Data) == 0 -> %empty file?
    file:close(State#client.handle).

%%
%% RRQ transfer loop
%%
send_file(State) ->
    Tid = State#client.tid,
    Offset = 512 * (Tid - 1),  % calculate chunk offset
    case file:pread(State#client.handle, {bof, Offset}, 512) of
        {ok, Content} ->
            send(State, <<0,3, Tid:16, Content/binary>>),
            State#client{tid = Tid + 1};
        eof ->
            send(State, <<0,3, Tid:16>>),
            file:close(State#client.handle),
            State#client{transfer = none};
        {error, Reason} ->
            io:format("Failed to process RRQ: ~p~n", [Reason]),
            send_error_msg(State, 0, Reason),
            State
    end.

send_error_msg(State, Code, Msg) ->
    EncodedMsg = atom_to_binary(Msg, latin1),
    send(State, <<0, 5, Code:16, EncodedMsg/binary, 0>>).

send(State, Data) ->
    gen_udp:send(State#client.socket, State#client.host, State#client.port, Data),
    State.