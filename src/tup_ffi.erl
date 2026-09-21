-module(tup_ffi).

-include_lib("kernel/include/file.hrl").

-export([parent/0, exit_with/1, gleam_error/1, erlang_term_to_string/1, parse_address/1, unlink_stale_socket/1, read_file/1,
         child_pid/2, terminate_child/2, restart_child/2, active_children/1,
         stop_supervisor/1, trapping_exits/1]).

parent() -> 
  {parent, Pid} = erlang:process_info(self(), parent), 
  Pid.

exit_with(Reason) -> erlang:exit(Reason).

gleam_error(#{gleam_error := Kind, message := Message, module := Module,
              function := Function, file := File, line := Line} = Error)
  when Kind =:= panic; Kind =:= todo; Kind =:= let_assert; Kind =:= assert ->
  Value = case Error of
    #{value := Unmatched} -> {some, Unmatched};
    _NoValue -> none
  end,
  {ok, {gleam_error, Kind, Message, Module, Function, File, Line, Value}};
gleam_error(_NotGleam) ->
  {error, nil}.

erlang_term_to_string(Term) ->
  unicode:characters_to_binary(io_lib:format("~0tp", [Term])).

parse_address(Address) ->
  case inet:parse_address(binary_to_list(Address)) of
    {ok, {A, B, C, D}} ->
      {ok, {ipv4, A, B, C, D}};
    {ok, {A, B, C, D, E, F, G, H}} ->
      {ok, {ipv6, A, B, C, D, E, F, G, H}};
    {error, einval} ->
      {error, nil}
  end.

read_file(Path) ->
  case file:read_file(Path) of
    {ok, Bytes} -> {ok, Bytes};
    {error, Reason} -> {error, reason(Reason)}
  end.

unlink_stale_socket(Path) ->
  case file:read_link_info(Path) of
    {error, enoent} ->
      {ok, nil};
    {ok, #file_info{type = other}} ->
      case file:delete(Path) of
        ok ->
          {ok, nil};
        {error, enoent} ->
          {ok, nil};
        {error, Reason} ->
          {error, {path_not_removed, reason(Reason)}}
      end;
    {ok, #file_info{type = Kind}} ->
      {error, {path_not_socket, path_kind(Kind)}};
    {error, Reason} ->
      {error, {path_not_inspected, reason(Reason)}}
  end.

path_kind(device) -> device;
path_kind(directory) -> directory;
path_kind(regular) -> regular;
path_kind(symlink) -> symlink;
path_kind(_Kind) -> unknown_kind.

reason(Reason) when is_atom(Reason) ->
  atom_to_binary(Reason, utf8);
reason(Reason) ->
  unicode:characters_to_binary(io_lib:format("~p", [Reason])).

child_pid(Supervisor, Id) ->
  try supervisor:which_children(Supervisor) of
    Children ->
      case lists:keyfind(Id, 1, Children) of
        {Id, Pid, _Type, _Modules} when is_pid(Pid) -> {ok, Pid};
        _NotRunning -> {error, nil}
      end
  catch
    exit:_Reason -> {error, nil}
  end.

terminate_child(Supervisor, Id) ->
  try supervisor:terminate_child(Supervisor, Id) of
    ok -> {ok, nil};
    {error, not_found} -> {error, nil}
  catch
    exit:_Reason -> {error, nil}
  end.

restart_child(Supervisor, Id) ->
  try supervisor:restart_child(Supervisor, Id) of
    {ok, _Pid} -> {ok, nil};
    {ok, _Pid, _Info} -> {ok, nil};
    {error, running} -> {ok, nil};
    {error, restarting} -> {ok, nil};
    {error, _Reason} -> {error, nil}
  catch
    exit:_Reason -> {error, nil}
  end.

active_children(Supervisor) ->
  try supervisor:count_children(Supervisor) of
    Counts -> {ok, proplists:get_value(active, Counts, 0)}
  catch
    exit:_Reason -> {error, nil}
  end.

stop_supervisor(Supervisor) ->
  try gen_server:stop(Supervisor) of
    ok -> nil
  catch
    exit:_Reason -> nil
  end.

trapping_exits(Start) ->
  Trapping = process_flag(trap_exit, true),
  try Start()
  after
    process_flag(trap_exit, Trapping),
    case Trapping of
      true -> ok;
      false -> replay_exits()
    end
  end.

replay_exits() ->
  receive
    {'EXIT', _Pid, normal} -> replay_exits();
    {'EXIT', _Pid, Reason} -> exit(Reason)
  after 0 -> ok
  end.
