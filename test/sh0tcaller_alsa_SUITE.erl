%%%-------------------------------------------------------------------
%% Tests for the ALSA layer with no ALSA hardware.
%%
%% Two seams make that possible. Card enumeration reads /proc/asound,
%% which the `proc_asound_dir' env points at a fixture built per test, so
%% the USB-detection logic is exercised for real rather than mocked.
%% Everything below that — the NIF and external commands — is mecked.
%%%-------------------------------------------------------------------

-module(sh0tcaller_alsa_SUITE).

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
         lists_only_capture_capable_cards/1,
         finds_the_usb_card_as_the_radio/1,
         refuses_to_guess_between_two_usb_cards/1,
         no_cards_without_proc_asound/1,
         record_returns_exactly_the_requested_duration/1,
         record_recovers_and_keeps_reading/1,
         capture_radio_falls_back_when_device_busy/1,
         capture_radio_reports_busy_without_a_pulse_source/1,
         write_wav_describes_the_samples/1
        ]).

-define(USB_CARD_NAME, "USB Audio CODEC").
-define(PULSE_SOURCE,
        "alsa_input.usb-Burr-Brown_from_TI_USB_Audio_CODEC-00.analog-stereo").

all() ->
    [lists_only_capture_capable_cards,
     finds_the_usb_card_as_the_radio,
     refuses_to_guess_between_two_usb_cards,
     no_cards_without_proc_asound,
     record_returns_exactly_the_requested_duration,
     record_recovers_and_keeps_reading,
     capture_radio_falls_back_when_device_busy,
     capture_radio_reports_busy_without_a_pulse_source,
     write_wav_describes_the_samples].

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    application:unset_env(sh0tcaller, proc_asound_dir),
    application:unset_env(sh0tcaller, radio_card),
    meck:unload(),
    ok.

%%====================================================================
%% Card enumeration
%%====================================================================

%% A playback-only card has no pcmNc directory and must not show up.
lists_only_capture_capable_cards(Config) ->
    fixture(Config, [{0, "PCH", "HDA Intel PCH", undefined, [capture]},
                     {1, "CODEC", ?USB_CARD_NAME, "08bb:2901", [capture]},
                     {2, "HDMI", "HDMI Audio", undefined, [playback]}]),
    Cards = sh0tcaller_alsa:list_capture_cards(),
    [0, 1] = [maps:get(index, C) || C <- Cards],
    ["PCH", "CODEC"] = [maps:get(id, C) || C <- Cards],
    [false, "08bb:2901"] = [maps:get(usb, C) || C <- Cards],
    ok.

%% The radio is identified by sitting on the USB bus, not by its name:
%% the built-in codec is equally capture-capable.
finds_the_usb_card_as_the_radio(Config) ->
    fixture(Config, [{0, "PCH", "HDA Intel PCH", undefined, [capture]},
                     {1, "CODEC", ?USB_CARD_NAME, "08bb:2901", [capture]}]),
    {ok, Radio} = sh0tcaller_alsa:find_radio(),
    1 = maps:get(index, Radio),
    "CODEC" = maps:get(id, Radio),
    {ok, "plughw:1,0"} = sh0tcaller_alsa:radio_device(),
    ok.

%% Guessing would silently record from the wrong device, so it reports
%% the candidates instead. Naming one resolves it.
refuses_to_guess_between_two_usb_cards(Config) ->
    fixture(Config, [{1, "CODEC", ?USB_CARD_NAME, "08bb:2901", [capture]},
                     {2, "OTHER", "Other USB Audio", "1234:5678", [capture]}]),
    {error, {ambiguous, Ids}} = sh0tcaller_alsa:find_radio(),
    ["CODEC", "OTHER"] = lists:sort(Ids),
    application:set_env(sh0tcaller, radio_card, "OTHER"),
    {ok, Chosen} = sh0tcaller_alsa:find_radio(),
    "OTHER" = maps:get(id, Chosen),
    ok.

%% A machine with no sound support has no /proc/asound at all. That is an
%% empty list, not a crash — callers only want to know if a radio is there.
no_cards_without_proc_asound(Config) ->
    Missing = filename:join(proplists:get_value(priv_dir, Config), "nonexistent"),
    application:set_env(sh0tcaller, proc_asound_dir, Missing),
    [] = sh0tcaller_alsa:list_capture_cards(),
    {error, no_usb_capture_card} = sh0tcaller_alsa:find_radio(),
    ok.

%%====================================================================
%% Recording
%%====================================================================

%% readi hands back whatever the period size yields, which overshoots the
%% requested duration; the surplus must be trimmed rather than returned.
record_returns_exactly_the_requested_duration(_Config) ->
    mock_pcm(fun() -> {ok, binary:copy(<<7, 0>>, 4096)} end),
    {ok, Audio} = sh0tcaller_alsa:record("plughw:1,0", 1000,
                                         #{rate => 8000, channels => 1}),
    %% 1 s of 8 kHz mono 16-bit.
    16000 = byte_size(Audio),
    ok.

%% An overrun mid-capture is recoverable: recover/2 then carry on, rather
%% than losing the recording.
record_recovers_and_keeps_reading(_Config) ->
    Counter = counters:new(1, []),
    mock_pcm(fun() ->
        case counters:get(Counter, 1) of
            0 ->
                counters:add(Counter, 1, 1),
                {error, epipe};
            _ ->
                {ok, binary:copy(<<1, 0>>, 4096)}
        end
    end),
    {ok, Audio} = sh0tcaller_alsa:record("plughw:1,0", 500,
                                         #{rate => 8000, channels => 1}),
    8000 = byte_size(Audio),
    true = meck:called(alsa_pcm, recover, [pcm_handle, epipe]),
    ok.

%% The raw device is exclusive, so anything going through PipeWire holds
%% it. Falling back to the shared bridge is what lets us record while
%% WSJT-X is running.
capture_radio_falls_back_when_device_busy(Config) ->
    fixture(Config, [{1, "CODEC", ?USB_CARD_NAME, "08bb:2901", [capture]}]),
    mock_pactl("65770\t" ?PULSE_SOURCE "\tPipeWire\ts16le 2ch 48000Hz\tRUNNING\n"),
    mock_pcm_busy_on_raw(),
    {ok, Audio} = sh0tcaller_alsa:capture_radio(500, #{rate => 8000,
                                                       channels => 1}),
    8000 = byte_size(Audio),
    %% It really did try the raw device first, then the bridge.
    true = meck:called(alsa_pcm, open, ["plughw:1,0", capture]),
    true = meck:called(alsa_pcm, open, ["pulse", capture]),
    ok.

%% Without a matching bridge source there is nowhere to fall back to, and
%% the original EBUSY is the useful thing to report.
capture_radio_reports_busy_without_a_pulse_source(Config) ->
    fixture(Config, [{1, "CODEC", ?USB_CARD_NAME, "08bb:2901", [capture]}]),
    mock_pactl("54\talsa_input.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts32le\tIDLE\n"),
    mock_pcm_busy_on_raw(),
    {error, ebusy} = sh0tcaller_alsa:capture_radio(500, #{rate => 8000,
                                                          channels => 1}),
    ok.

%%====================================================================
%% Wav
%%====================================================================

%% A header that disagrees with the samples yields a file that plays at
%% the wrong speed while looking perfectly valid.
write_wav_describes_the_samples(Config) ->
    Path = filename:join(proplists:get_value(priv_dir, Config), "out.wav"),
    Audio = binary:copy(<<0, 0>>, 8000),
    ok = sh0tcaller_alsa:write_wav(Path, Audio, #{rate => 8000, channels => 1}),
    {ok, Wav} = file:read_file(Path),
    <<"RIFF", RiffSize:32/little, "WAVE",
      "fmt ", 16:32/little, 1:16/little, Channels:16/little,
      Rate:32/little, ByteRate:32/little, BlockAlign:16/little, Bits:16/little,
      "data", DataSize:32/little, Rest/binary>> = Wav,
    1 = Channels,
    8000 = Rate,
    16 = Bits,
    2 = BlockAlign,
    16000 = ByteRate,
    16000 = DataSize,
    16000 = byte_size(Rest),
    RiffSize = byte_size(Wav) - 8,
    ok.

%%====================================================================
%% Helpers
%%====================================================================

%% Builds a /proc/asound good enough for enumeration: a cards file with
%% two lines per card, plus a directory per card holding id, usbid and a
%% pcmNc/pcmNp per device.
fixture(Config, Cards) ->
    Root = filename:join(proplists:get_value(priv_dir, Config), "asound"),
    %% priv_dir is per suite, not per case, so a card left behind by an
    %% earlier case would show up as an extra one here.
    _ = file:del_dir_r(Root),
    ok = filelib:ensure_path(Root),
    Lines = [io_lib:format("~2b [~-15s]: Driver - ~s\n                      ~s at usb-x\n",
                           [Index, Id, Name, Name])
             || {Index, Id, Name, _Usb, _Devices} <- Cards],
    ok = file:write_file(filename:join(Root, "cards"), Lines),
    lists:foreach(fun({Index, Id, _Name, Usb, Devices}) ->
        Dir = filename:join(Root, "card" ++ integer_to_list(Index)),
        ok = filelib:ensure_path(Dir),
        ok = file:write_file(filename:join(Dir, "id"), Id ++ "\n"),
        case Usb of
            undefined -> ok;
            _ -> ok = file:write_file(filename:join(Dir, "usbid"), Usb ++ "\n")
        end,
        lists:foreach(fun
            (capture) -> ok = filelib:ensure_path(filename:join(Dir, "pcm0c"));
            (playback) -> ok = filelib:ensure_path(filename:join(Dir, "pcm0p"))
        end, Devices)
    end, Cards),
    application:set_env(sh0tcaller, proc_asound_dir, Root),
    Root.

%% A PCM whose reads come from Read(). frame_size is 2 so the byte
%% arithmetic matches 16-bit mono.
mock_pcm(Read) ->
    meck:new(alsa_pcm, [non_strict]),
    meck:expect(alsa_pcm, open, fun(_Device, capture) -> {ok, pcm_handle} end),
    meck:expect(alsa_pcm, set_params, fun(_, _) -> ok end),
    meck:expect(alsa_pcm, start, fun(_) -> ok end),
    meck:expect(alsa_pcm, frame_size, fun(_) -> 2 end),
    meck:expect(alsa_pcm, close, fun(_) -> ok end),
    meck:expect(alsa_pcm, recover, fun(_, _) -> ok end),
    meck:expect(alsa_pcm, readi, fun(_, _) -> Read() end).

%% The raw device is held by someone else; the bridge is free.
mock_pcm_busy_on_raw() ->
    mock_pcm(fun() -> {ok, binary:copy(<<3, 0>>, 4096)} end),
    meck:expect(alsa_pcm, open, fun
        ("pulse", capture) -> {ok, pcm_handle};
        (_Raw, capture) -> {error, ebusy}
    end).

mock_pactl(Output) ->
    meck:new(sh0tcaller_cmd, [passthrough]),
    meck:expect(sh0tcaller_cmd, run,
                fun("pactl", ["list", "short", "sources"]) -> {ok, 0, Output} end).
