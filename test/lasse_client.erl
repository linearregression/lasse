%%% @doc HTTP client for testing using gun.
-module(lasse_client).

-export([
         open/2,
         close/1,
         get/2,
         get/3
        ]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Public functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec open(Host :: string(), Port :: integer()) -> {ok, pid()}.
open(Host, Port) ->
    proc_lib:spawn_link(fun () -> init(Host, Port) end).

-spec close(pid()) -> ok.
close(Pid) ->
    Pid ! 'shutdown',
    ok.

-spec get(Pid :: pid(), Url :: string()) -> ok.
get(Pid, Url) ->
    get(Pid, Url, []),
    ok.

-type headers() :: [{binary(), binary()}].

-spec get(Pid :: pid(), Url :: string(), Headers :: headers()) -> ok.
get(Pid, Url, Headers) ->
    Pid ! {get, self(), Url, Headers},
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Local functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Host, Port) ->
    Opts = [
            {type, tcp},
            {retry, 1},
            {retry_timeout, 1}
           ],
    {ok, Pid} = gun:open(Host, Port, Opts),
    loop(Pid).

loop(Pid) ->
    receive
        {get, From, Url, Headers} ->
            lager:info("Getting ~p", [Url]),
            StreamRef = gun:get(Pid, Url, Headers),
            response(Pid, StreamRef, From),
            loop(Pid);
        shutdown ->
            gun:shutdown(Pid)
    end.

response(Pid, StreamRef, From) ->
    receive
        {'DOWN', _, _, _, Reason} ->
            exit(Reason);
        {gun_response, Pid, StreamRef, fin, _Status, _Headers} ->
            no_data;
        {gun_response, Pid, StreamRef, nofin, _Status, Headers} ->
            case  lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
                {<<"transfer-encoding">>, <<"chunked">>} ->
                    receive_chunks(StreamRef, From);
                false ->
                    receive_data(StreamRef, From)
            end
    after 5000 ->
            exit(response_timeout)
    end.

receive_data(StreamRef, From) ->
    receive_data(StreamRef, From, <<"">>).

receive_data(StreamRef, From, DataAcc) ->
    receive
        {'DOWN', _Tag, _, _, _Reason} ->
            {error, incomplete};
        {gun_data, _Pid, StreamRef, nofin, Data} ->
            receive_data(StreamRef, <<DataAcc/binary, Data/binary>>);
        {gun_data, _Pid, StreamRef, fin, Data} ->
            From ! {response, <<DataAcc/binary, Data/binary>>},
            ok
    after 5000 ->
        {error, timeout}
    end.

receive_chunks(StreamRef, From) ->
    receive
        {'DOWN', _Tag, _, _, _Reason} ->
            {error, incomplete};
        {gun_data, _Pid, StreamRef, nofin, Data} ->
            From ! {chunk, Data},
            receive_chunks(StreamRef, From);
        {gun_data, _Pid, StreamRef, fin, Data} ->
            From ! {chunk, Data},
            ok
    after 5000 ->
        {error, timeout}
    end.
