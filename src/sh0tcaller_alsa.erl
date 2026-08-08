-module(sh0tcaller_alsa).

-moduledoc """
ALSA capture: find the sound cards we can record from, pick out the radio
interface, and record from it to a wav file.

The radio is a USB audio interface, so it is identified by being the
capture-capable card that sits on the USB bus (the built-in HDA codec is
not). Override with `application:set_env(sh0tcaller, radio_card, "CODEC")`
when more than one USB capture device is plugged in.
""".

-export([
         list_capture_cards/0,
         find_radio/0,
         radio_device/0,
         pulse_source/1,
         capture_radio/2,
         record_radio/2,
         record_radio/3,
         record/3,
         write_wav/3
        ]).

-define(RATE, 8000).
-define(CHANNELS, 1).
-define(FORMAT, s16_le).
-define(SAMPLE_BITS, 16).

%% erlang-alsa reports EBUSY as the atom ebusy. Older builds of the NIF
%% passed unnamed errnos through as integers, so accept 16 as well rather
%% than silently losing the fallback against a stale _build.
-define(EBUSY_ERRNO, 16).

-doc "A sound card, as described by /proc/asound.".
-type card() :: #{
    index := non_neg_integer(),
    id := string(),
    driver := string(),
    name := string(),
    longname := string(),
    usb := false | string(),
    capture_devices := [non_neg_integer()]
}.

-export_type([card/0]).

%%====================================================================
%% Cards
%%====================================================================

-doc """
Every sound card with at least one capture device, lowest index first.

erlang-alsa has no enumeration of its own, so this reads /proc/asound: a
card exposes `pcmNc` per capture device, and `usbid` only when it is a USB
device.
""".
-spec list_capture_cards() -> [card()].
list_capture_cards() ->
    [Card || Card <- all_cards(), maps:get(capture_devices, Card) =/= []].

-doc """
The radio's card.

Prefers the `radio_card` application env (a card id such as `"CODEC"`, or
an integer index) and otherwise picks the single USB capture card.
""".
-spec find_radio() -> {ok, card()} | {error, term()}.
find_radio() ->
    Cards = list_capture_cards(),
    case application:get_env(sh0tcaller, radio_card) of
        {ok, Wanted} ->
            case [C || C <- Cards, matches(Wanted, C)] of
                [Card] -> {ok, Card};
                [] -> {error, {configured_radio_not_found, Wanted}};
                Many -> {error, {ambiguous, ids(Many)}}
            end;
        undefined ->
            case [C || C <- Cards, maps:get(usb, C) =/= false] of
                [Card] -> {ok, Card};
                [] -> {error, no_usb_capture_card};
                Many -> {error, {ambiguous, ids(Many)}}
            end
    end.

-doc """
ALSA device string for the radio, e.g. `"plughw:1,0"`.

plughw rather than hw, so that rate and channel conversion are available
if the hardware will not take them directly.
""".
-spec radio_device() -> {ok, string()} | {error, term()}.
radio_device() ->
    case find_radio() of
        {ok, Card} -> {ok, device_name(Card)};
        {error, _} = Error -> Error
    end.

%%====================================================================
%% Recording
%%====================================================================

-doc """
Record `DurationMs` of audio from the radio at 8 kHz mono and write it to
`Path` as a 16-bit PCM wav file.
""".
-spec record_radio(pos_integer(), file:name_all()) -> ok | {error, term()}.
record_radio(DurationMs, Path) ->
    record_radio(DurationMs, Path, #{}).

-doc "As `record_radio/2`, with `rate` and `channels` overridable.".
-spec record_radio(pos_integer(), file:name_all(), map()) -> ok | {error, term()}.
record_radio(DurationMs, Path, Opts) ->
    case capture_radio(DurationMs, Opts) of
        {ok, Audio} -> write_wav(Path, Audio, Opts);
        {error, _} = Error -> Error
    end.

-doc """
Capture from the radio and return the samples.

The raw ALSA device is exclusive: while WSJT-X (or anything else going
through PipeWire) holds it, opening plughw fails with `EBUSY`. In that
case this retries through the PulseAudio/PipeWire bridge, which shares, so
recording alongside a running WSJT-X works.
""".
-spec capture_radio(pos_integer(), map()) -> {ok, binary()} | {error, term()}.
capture_radio(DurationMs, Opts) ->
    case find_radio() of
        {ok, Card} ->
            case record(device_name(Card), DurationMs, Opts) of
                {error, Reason} = Busy
                  when Reason =:= ebusy; Reason =:= ?EBUSY_ERRNO ->
                    capture_shared(Card, DurationMs, Opts, Busy);
                Result ->
                    Result
            end;
        {error, _} = Error ->
            Error
    end.

%% PULSE_SOURCE is read by the ALSA pulse plugin when the device is
%% opened, and the emulator has one environment, so concurrent captures
%% from different cards would race here.
capture_shared(Card, DurationMs, Opts, Busy) ->
    case pulse_source(Card) of
        {ok, Source} ->
            os:putenv("PULSE_SOURCE", Source),
            try record("pulse", DurationMs, Opts)
            after
                os:unsetenv("PULSE_SOURCE")
            end;
        {error, _} ->
            Busy
    end.

-doc """
The PipeWire/PulseAudio source that corresponds to a card.

PipeWire derives node names from the ALSA card name, so card
`"USB Audio CODEC"` becomes
`alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo`.
""".
-spec pulse_source(card()) -> {ok, string()} | {error, term()}.
pulse_source(#{name := Name}) ->
    Fragment = lists:flatten(string:replace(Name, " ", "_", all)),
    case [S || S <- pulse_sources(), string:find(S, Fragment) =/= nomatch] of
        [Source] -> {ok, Source};
        [] -> {error, {no_pulse_source_for, Name}};
        Many -> {error, {ambiguous_pulse_sources, Many}}
    end.

pulse_sources() ->
    case sh0tcaller_cmd:run("pactl", ["list", "short", "sources"]) of
        {ok, 0, Output} ->
            [Name || Line <- string:split(Output, "\n", all),
                     [_Id, Name | _] <- [string:lexemes(Line, "\t ")],
                     lists:prefix("alsa_input.", Name)];
        _ ->
            []
    end.

-doc """
Record exactly `DurationMs` worth of interleaved samples from `Device` and
return them as a binary.
""".
-spec record(string(), pos_integer(), map()) -> {ok, binary()} | {error, term()}.
record(Device, DurationMs, Opts) ->
    Rate = maps:get(rate, Opts, ?RATE),
    Channels = maps:get(channels, Opts, ?CHANNELS),
    case alsa_pcm:open(Device, capture) of
        {ok, PCM} ->
            try
                ok = alsa_pcm:set_params(PCM, #{
                    format => ?FORMAT,
                    access => rw_interleaved,
                    channels => Channels,
                    rate => Rate,
                    rate_resample => true,
                    latency => 100000
                }),
                ok = alsa_pcm:start(PCM),
                Frames = DurationMs * Rate div 1000,
                read_exactly(PCM, alsa_pcm:frame_size(PCM) * Frames, [])
            after
                alsa_pcm:close(PCM)
            end;
        {error, _} = Error ->
            Error
    end.

read_exactly(_PCM, Remaining, Acc) when Remaining =< 0 ->
    {ok, iolist_to_binary(lists:reverse(Acc))};
read_exactly(PCM, Remaining, Acc) ->
    case alsa_pcm:readi(PCM, infinity) of
        {ok, Data} when byte_size(Data) >= Remaining ->
            <<Wanted:Remaining/binary, _/binary>> = Data,
            read_exactly(PCM, 0, [Wanted | Acc]);
        {ok, Data} ->
            read_exactly(PCM, Remaining - byte_size(Data), [Data | Acc]);
        {error, Error} ->
            case alsa_pcm:recover(PCM, Error) of
                ok -> read_exactly(PCM, Remaining, Acc);
                {error, _} = Fatal -> Fatal
            end
    end.

%%====================================================================
%% Wav
%%====================================================================

-doc """
Write 16-bit PCM samples as a wav file.

The header must describe the rate and channel count the samples were
captured at, or the file plays back at the wrong speed.
""".
-spec write_wav(file:name_all(), binary(), map()) -> ok | {error, term()}.
write_wav(Path, Audio, Opts) ->
    Rate = maps:get(rate, Opts, ?RATE),
    Channels = maps:get(channels, Opts, ?CHANNELS),
    BlockAlign = Channels * ?SAMPLE_BITS div 8,
    ByteRate = Rate * BlockAlign,
    DataSize = byte_size(Audio),
    Fmt = <<"fmt ", 16:32/little, 1:16/little, Channels:16/little,
            Rate:32/little, ByteRate:32/little,
            BlockAlign:16/little, ?SAMPLE_BITS:16/little>>,
    RiffSize = 4 + byte_size(Fmt) + 8 + DataSize,
    file:write_file(Path, <<"RIFF", RiffSize:32/little, "WAVE",
                            Fmt/binary,
                            "data", DataSize:32/little, Audio/binary>>).

%%====================================================================
%% /proc/asound
%%====================================================================

device_name(#{index := Index, capture_devices := [Device | _]}) ->
    lists:flatten(io_lib:format("plughw:~b,~b", [Index, Device])).

matches(Index, #{index := Index}) when is_integer(Index) -> true;
matches(Id, #{id := Id}) -> true;
matches(_, _) -> false.

ids(Cards) ->
    [maps:get(id, Card) || Card <- Cards].

all_cards() ->
    Descriptions = card_descriptions(),
    case file:list_dir("/proc/asound") of
        {ok, Entries} ->
            Indexes = lists:sort([I || E <- Entries, {ok, I} <- [card_index(E)]]),
            [card_info(I, Descriptions) || I <- Indexes];
        {error, Reason} ->
            error({proc_asound_unreadable, Reason})
    end.

card_index("card" ++ Digits) ->
    try {ok, list_to_integer(Digits)}
    catch error:badarg -> error
    end;
card_index(_) ->
    error.

card_info(Index, Descriptions) ->
    Dir = "/proc/asound/card" ++ integer_to_list(Index),
    {Driver, Name, LongName} = maps:get(Index, Descriptions, {"", "", ""}),
    #{index => Index,
      id => read_line(filename:join(Dir, "id")),
      driver => Driver,
      name => Name,
      longname => LongName,
      usb => case read_line(filename:join(Dir, "usbid")) of
                 "" -> false;
                 UsbId -> UsbId
             end,
      capture_devices => capture_devices(Dir)}.

capture_devices(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:sort([D || E <- Entries, {ok, D} <- [pcm_capture_index(E)]]);
        {error, _} ->
            []
    end.

%% Capture devices are pcmNc, playback pcmNp.
pcm_capture_index("pcm" ++ Rest) ->
    case lists:reverse(Rest) of
        [$c | RevDigits] ->
            try {ok, list_to_integer(lists:reverse(RevDigits))}
            catch error:badarg -> error
            end;
        _ ->
            error
    end;
pcm_capture_index(_) ->
    error.

%% /proc/asound/cards holds two lines per card:
%%   " 1 [CODEC          ]: USB-Audio - USB Audio CODEC"
%%   "                      Burr-Brown from TI USB Audio CODEC at usb-..."
card_descriptions() ->
    case file:read_file("/proc/asound/cards") of
        {ok, Contents} ->
            Lines = string:split(binary_to_list(Contents), "\n", all),
            card_descriptions(Lines, #{});
        {error, _} ->
            #{}
    end.

card_descriptions([Head, LongName | Rest], Acc) ->
    case parse_card_line(Head) of
        {ok, Index, Driver, Name} ->
            Description = {Driver, Name, string:trim(LongName)},
            card_descriptions(Rest, Acc#{Index => Description});
        error ->
            card_descriptions([LongName | Rest], Acc)
    end;
card_descriptions(_, Acc) ->
    Acc.

parse_card_line(Line) ->
    case string:split(Line, ":") of
        [Left, Right] ->
            case string:split(string:trim(Left), "[") of
                [IndexText, _IdText] ->
                    try
                        Index = list_to_integer(string:trim(IndexText)),
                        {Driver, Name} = split_driver(string:trim(Right)),
                        {ok, Index, Driver, Name}
                    catch
                        error:badarg -> error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

split_driver(Text) ->
    case string:split(Text, " - ") of
        [Driver, Name] -> {Driver, Name};
        [Driver] -> {Driver, ""}
    end.

read_line(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> string:trim(binary_to_list(Contents));
        {error, _} -> ""
    end.
