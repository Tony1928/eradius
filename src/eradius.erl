-module(eradius).
%%%-------------------------------------------------------------------
%%% File        : eradius.erl
%%% Author      : {mbj,tobbe}@bluetail.com>
%%% Description : RADIUS Authentication
%%% Created     :  7 Oct 2002 by Martin Bjorklund <mbj@bluetail.com>
%%%-------------------------------------------------------------------
-behaviour(gen_server).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("eradius.hrl").
-include("eradius_lib.hrl").

%%--------------------------------------------------------------------
%% External exports

-export([
         start_link/0,
         start/0,
         stop/0
        ]).

-export([auth/1, auth/3, auth/4, default_port/0,
         load_tables/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
	 code_change/3]).

%% Internal exports
-export([worker/5]).

-record(state, {}).

-define(SERVER    , ?MODULE).
-define(TABLENAME , ?MODULE).

default_port() -> 1812.

start() ->
    application:start(eradius).

stop() ->
    application:stop(eradius).


%%====================================================================
%% External functions
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%-----------------------------------------------------------------
%% --- Authenticate a user. ---
%%
%% The auth() function can return either of:
%%
%%    {accept, AttributeList}
%%    {reject, AttributeList}
%%    {reject, ErrorCode}
%%    {challenge, ChallengeState, ReplyMsg}
%%
%%-----------------------------------------------------------------

auth(E) ->
    auth(E, E#eradius.user, E#eradius.passwd, E#eradius.state).

auth(E, User, Passwd) ->
    auth(E, User, Passwd, E#eradius.state).

auth(E, User, Passwd, CallState) when is_record(E, eradius) ->
    gen_server:call(?SERVER, {auth, E, User, Passwd, CallState},
		   infinity).

load_tables(Tables) ->
    eradius_dict:load_tables(Tables).

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function:    init/1
%%
%% Description: Setup a server which starts/controls the worker
%%              processes which talk SMB authentication. There
%%              is one worker per SMB-XNET "domain".
%%
%% Returns:     {ok, State}
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    ets:new(?TABLENAME, [named_table, public]),
    ets:insert(?TABLENAME, {id_counter, 0}),
    {ok, #state{}}.

handle_call({auth, E, User, Passwd, CState}, From, State) ->
    proc_lib:spawn(?MODULE, worker, [From, E, User, Passwd, CState]),
    {noreply, State}.

handle_cast(_Req, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State };
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%%
%%% Worker process, performing the Radius request.
%%%

worker(From, E, User, Passwd, CState) ->
    process_flag(trap_exit, true),
    Servers = E#eradius.servers,
    State = if CState /= <<>> -> binary_to_term(CState);
	       true -> <<>>
	    end,
    case catch wloop(E, User, Passwd, Servers, State) of
	{'EXIT', R} ->
	    gen_server:reply(From, {reject, ?AL_Internal_Error}),
	    exit(R);
	R ->
	    gen_server:reply(From, R)
    end.

wloop(E, User, Passwd, _, {{Ip,Port,Secret}, State}) ->
    %% Make sure the challenge reply goes to the same Radius server.
    wloop(E, User, Passwd, [[Ip,Port,Secret]], State);
wloop(E, User0, Passwd0, [[Ip,Port,Secret0]|Srvs], State) ->
    Id = ets:update_counter(?TABLENAME, id_counter, 1),
    Auth = eradius_lib:mk_authenticator(),
    Secret = list_to_binary(Secret0),
    Passwd = list_to_binary(Passwd0),
    User   = list_to_binary(User0),
    RPasswd = eradius_lib:mk_password(Secret, Auth, Passwd),
    Pdu = #rad_pdu{reqid = Id,
		   authenticator = Auth,
		   cmd = #rad_request{user = User,
				      passwd = RPasswd,
				      state = State,
				      nas_ip = E#eradius.nas_ip_address}},
    ?TRACEFUN(E,"sending RADIUS request for ~s to ~p",
	      [binary_to_list(User), {Ip, Port}]),
    Req = eradius_lib:enc_pdu(Pdu),
    _StatKey = [E, Ip, Port],
    {ok, S} = gen_udp:open(0, [binary]),
    gen_udp:send(S, Ip, Port, Req),
    Resp = receive
	{udp, S, _IP, _Port, Packet} ->
	    eradius_lib:dec_packet(Packet)
    after E#eradius.timeout ->
	    timeout
    end,
    gen_udp:close(S),
    case decode_response(Resp, E) of
	timeout ->
	    ?STATFUN_TIMEDOUT(E, Ip, Port),
	    ?TRACEFUN(E,"RADIUS request for ~p timed out", [{Ip, Port}]),
	    wloop(E, User, Passwd, Srvs, State);
	{challenge, CState, Rmsg} ->
	    %% Wrap the call-state with the server
	    %% to be used in the next attempt.
	    WState = {{Ip,Port,Secret0}, CState},
	    {challenge, term_to_binary(WState), Rmsg};
	{accept, Attribs} ->
	    ?STATFUN_ACCEPTED(E, Ip, Port),
	    ?TRACEFUN(E,"got RADIUS reply Accept for ~s with attributes: ~p",
		      [binary_to_list(User), Attribs]),
	    {accept, Attribs};
	{reject, Resp} ->
	    ?STATFUN_REJECTED(E, Ip, Port),
	    ?TRACEFUN(E,"got RADIUS reply Reject for ~s",
		      [binary_to_list(User)]),
	    {reject, Resp};
	_Err ->
	    error_logger:format("~w: reject due to ~p\n", [?MODULE, _Err]),
	    ?STATFUN_REJECTED(E, Ip, Port), % correct to increment here ?
	    {reject, ?AL_Internal_Error}
    end;
wloop(E, User, _Passwd, [], _State) ->
    ?TRACEFUN(E,"no more RADIUS servers to try for ~s",[binary_to_list(User)]),
    {reject, ?AL_Backend_Unreachable}.

decode_response(Resp, _E) when is_record(Resp, rad_pdu) ->
    Resp#rad_pdu.cmd;
decode_response(timeout, _AuthSpec) ->
    timeout;
decode_response(Resp, _AuthSpec) ->
    Resp. % can't end up here really...
