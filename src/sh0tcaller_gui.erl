-module(sh0tcaller_gui).

-moduledoc """
Main window: two scrollable panes above a Monitor button.

The left pane lists every decode as it arrives, the right one is reserved
for per-frequency traffic and stays empty for now. The button starts and
stops monitoring, and the window subscribes to the monitor so decodes
appear here as well as on stdout.

Start it from a shell that already has the application running:

```erlang
sh0tcaller_gui:start().
```
""".

-behaviour(wx_object).

-include_lib("wx/include/wx.hrl").

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_event/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-define(BUTTON_MONITOR, 4001).

-doc "Open the main window.".
-spec start() -> wx:wx_object().
start() ->
    wx_object:start({local, ?MODULE}, ?MODULE, [], []).

-doc "Open the main window, linked to the caller.".
-spec start_link() -> wx:wx_object().
start_link() ->
    wx_object:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Close the main window.".
-spec stop() -> ok.
stop() ->
    wx_object:call(?MODULE, stop).

%%====================================================================
%% wx_object
%%====================================================================

-doc false.
init([]) ->
    %% wx is not in the application's dependency list: declaring it would
    %% make the whole application unstartable on a build of OTP without
    %% wx, which is exactly what the headless test machines are.
    {ok, _} = application:ensure_all_started(wx),
    {ok, _} = application:ensure_all_started(sh0tcaller),

    Wx = wx:new(),
    Frame = wxFrame:new(Wx, ?wxID_ANY, "sh0tcaller", [{size, {1000, 620}}]),
    Panel = wxPanel:new(Frame),

    %% Decodes are columnar, so they only line up in a fixed-width font.
    Font = wxFont:new(10, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL,
                      ?wxFONTWEIGHT_NORMAL),

    {DecodesBox, Decodes} = pane(Panel, Font, "Band activity"),
    {ReservedBox, Reserved} = pane(Panel, Font, "Rx frequency"),

    Button = wxButton:new(Panel, ?BUTTON_MONITOR, [{label, "Monitor"}]),
    Status = wxStaticText:new(Panel, ?wxID_ANY, "idle"),

    Panes = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Panes, DecodesBox, [{proportion, 2},
                                    {flag, ?wxEXPAND bor ?wxALL},
                                    {border, 4}]),
    wxSizer:add(Panes, ReservedBox, [{proportion, 1},
                                     {flag, ?wxEXPAND bor ?wxALL},
                                     {border, 4}]),

    Controls = wxBoxSizer:new(?wxHORIZONTAL),
    wxSizer:add(Controls, Button, [{flag, ?wxALIGN_CENTRE_VERTICAL bor ?wxALL},
                                   {border, 4}]),
    wxSizer:add(Controls, Status, [{flag, ?wxALIGN_CENTRE_VERTICAL bor ?wxLEFT},
                                   {border, 8}]),

    Main = wxBoxSizer:new(?wxVERTICAL),
    wxSizer:add(Main, Panes, [{proportion, 1}, {flag, ?wxEXPAND}]),
    wxSizer:add(Main, Controls, [{proportion, 0}, {flag, ?wxEXPAND bor ?wxALL},
                                 {border, 2}]),
    wxPanel:setSizer(Panel, Main),

    wxButton:connect(Button, command_button_clicked),
    wxFrame:connect(Frame, close_window),
    wxFrame:show(Frame),

    {Frame, #{frame => Frame,
              decodes => Decodes,
              reserved => Reserved,
              button => Button,
              status => Status,
              monitoring => false}}.

-doc false.
handle_event(#wx{id = ?BUTTON_MONITOR,
                 event = #wxCommand{type = command_button_clicked}}, State) ->
    {noreply, toggle_monitoring(State)};

handle_event(#wx{event = #wxClose{}}, State) ->
    {stop, normal, stop_monitoring(State)};

handle_event(_Event, State) ->
    {noreply, State}.

-doc false.
handle_call(stop, _From, State) ->
    {stop, normal, ok, stop_monitoring(State)};

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

-doc false.
handle_info({sh0tcaller_decodes, _Path, []}, State) ->
    {noreply, State};

handle_info({sh0tcaller_decodes, _Path, Decodes}, State) ->
    lists:foreach(fun(Decode) -> append(State, format(Decode)) end, Decodes),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

-doc false.
terminate(_Reason, #{frame := Frame}) ->
    try wxFrame:destroy(Frame)
    catch _:_ -> ok
    end,
    wx:destroy(),
    ok.

-doc false.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

%% A read-only multiline text control scrolls on its own and, unlike a
%% list control, keeps the columns jt9 already formats.
pane(Parent, Font, Label) ->
    Box = wxStaticBoxSizer:new(?wxVERTICAL, Parent, [{label, Label}]),
    Text = wxTextCtrl:new(Parent, ?wxID_ANY,
                          [{style, ?wxTE_MULTILINE bor ?wxTE_READONLY bor
                                   ?wxTE_DONTWRAP}]),
    wxTextCtrl:setFont(Text, Font),
    wxSizer:add(Box, Text, [{proportion, 1}, {flag, ?wxEXPAND}]),
    {Box, Text}.

toggle_monitoring(#{monitoring := false} = State) ->
    case sh0tcaller_ft8_sup:start_monitor() of
        {ok, _Pid} ->
            ok = sh0tcaller_ft8_monitor:subscribe(self()),
            set_status(State, "monitoring"),
            wxButton:setLabel(maps:get(button, State), "Stop"),
            State#{monitoring := true};
        {error, Reason} ->
            set_status(State, io_lib:format("cannot start: ~p", [Reason])),
            State
    end;
toggle_monitoring(#{monitoring := true} = State) ->
    stop_monitoring(State).

stop_monitoring(#{monitoring := false} = State) ->
    State;
stop_monitoring(#{monitoring := true} = State) ->
    _ = sh0tcaller_ft8_sup:stop_monitor(),
    set_status(State, "idle"),
    wxButton:setLabel(maps:get(button, State), "Monitor"),
    State#{monitoring := false}.

set_status(#{status := Status}, Text) ->
    wxStaticText:setLabel(Status, lists:flatten(Text)).

append(#{decodes := Decodes}, Line) ->
    wxTextCtrl:appendText(Decodes, unicode:characters_to_list([Line, $\n])).

format(#{time := Time, snr := Snr, dt := Dt, freq := Freq,
         message := Message}) ->
    io_lib:format("~6s ~4b ~5.1f ~5b  ~ts", [Time, Snr, Dt, Freq, Message]).
