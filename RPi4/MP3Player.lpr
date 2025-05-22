program MP3Player;

{$mode delphi} {Default to Delphi compatible syntax}
{$H+}          {Default to AnsiString}

{                                                                              }
{ MP3 Player with Ultibo and libmad                                            }
{                                                                              }
{ Based on the 20-PWMSound example.                                            }
{ https://github.com/ultibohub/Examples/tree/master/20-PWMSound/RPi4           }
{                                                                              }

{Declare some units used by this Program}
uses
  RaspberryPi4,
  GlobalConfig,
  GlobalConst,
  GlobalTypes,
  Platform,
  Threads,
  Console,
  Classes,
  SysUtils,
  mad,		{Include the mad unit to allow access to libmad functions}
  PWM,          {Include the PWM unit to allow access to the functions}
  BCM2711,      {Include the BCM2711 and BCM2838 units for access to the PWM device}
  BCM2838;      {and PWM register values and constants.}
  
{We'll need a window handle and a couple of PWM device references.}    
var
 Handle:THandle;
 PWM0Device:PPWMDevice;
 PWM1Device:PPWMDevice;
 umad_stream:mad_stream;
 umad_frame:mad_frame;
 umad_synth:mad_synth;
 channel_count:Word;
 bit_count,samplerate,resMP3:LongWord;
 bufout:PChar;
 nmp3i: Cardinal;
 
const
 PWMSOUND_PWM_OSC_CLOCK = 54000000;   
 PWMSOUND_PWM_PLLD_CLOCK = 750000000;
 SOUND_BITS = 16;
 CLOCK_RATE = 125000000;
 StreamSize = 1152 * 4;
 BufoutSize = 80 * 1024 * 1024;

{ Rounds MAD's high-resolution samples down to 16 bits }
function Scale(sample: mad_fixed_t): SmallInt;
begin
  { round }
  sample := sample + (1 shl (MAD_F_FRACBITS - 16));
  { clip }
  if sample >= MAD_F_ONE then
    sample := MAD_F_ONE - 1
  else if sample < -MAD_F_ONE then
    sample := -MAD_F_ONE;
  { quantize }
  sample := sample shr (MAD_F_FRACBITS + 1 - 16);
  Result := SmallInt(sample);
end;
 
function PWMSoundClockStart(PWM:PPWMDevice;Frequency:LongWord):LongWord; 
var
 DivisorI:LongWord;
 DivisorR:LongWord;
 DivisorF:LongWord;
begin
 {}
 Result:=ERROR_INVALID_PARAMETER;
 
 {Check PWM}
 if PWM = nil then Exit;
 
 {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound: PWM Clock Start');
 {$ENDIF}
 
 {Check Frequency} 
 if Frequency = 0 then Exit;

 {Check Enabled}
 if not BCM2711PWM0ClockEnabled(PWM) then
  begin
   {Get Divisors}
   DivisorI:=PWMSOUND_PWM_PLLD_CLOCK div Frequency;
   DivisorR:=PWMSOUND_PWM_PLLD_CLOCK mod Frequency;
   DivisorF:=Trunc((DivisorR * 4096) / PWMSOUND_PWM_PLLD_CLOCK);
   
   if DivisorI > 4095 then DivisorI:=4095;
  
   {Memory Barrier}
   DataMemoryBarrier; {Before the First Write}
  
   {Set Dividers}
   PLongWord(BCM2838_CM_REGS_BASE + BCM2838_CM_PWMDIV)^:=BCM2838_CM_PASSWORD or (DivisorI shl 12) or DivisorF;
   {Delay}
   MicrosecondDelay(10);
  
   {Set Source}   
   PLongWord(BCM2838_CM_REGS_BASE + BCM2838_CM_PWMCTL)^:=BCM2838_CM_PASSWORD or BCM2838_CM_CTL_SRC_PLLD;
   {Delay}
   MicrosecondDelay(10);
  
   {Start Clock}   
   PLongWord(BCM2838_CM_REGS_BASE + BCM2838_CM_PWMCTL)^:=BCM2838_CM_PASSWORD or PLongWord(BCM2838_CM_REGS_BASE + BCM2838_CM_PWMCTL)^ or BCM2838_CM_CTL_ENAB;
   {Delay}
   MicrosecondDelay(110);
   
   {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
   if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  DivisorI=' + IntToStr(DivisorI));
   if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  DivisorF=' + IntToStr(DivisorF));
   if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  PWMCTL=' + IntToHex(PLongWord(BCM2838_CM_REGS_BASE + BCM2838_CM_PWMCTL)^,8));
   if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  PWMDIV=' + IntToHex(PLongWord(BCM2838_CM_REGS_BASE + BCM2838_CM_PWMDIV)^,8));
   {$ENDIF}
   
   {Memory Barrier}
   DataMemoryBarrier; {After the Last Read} 
  end;

 {Return Result}
 Result:=ERROR_SUCCESS;  
end; 

function PWMSoundStart(PWM:PPWMDevice):LongWord; 
begin
 {}
 Result:=ERROR_INVALID_PARAMETER;
 
 {Check PWM}
 if PWM = nil then Exit;
 
 {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound: PWM Start');
 {$ENDIF}
 
 {Check Settings}
 if PWM.Range = 0 then Exit;
 if PWM.Frequency = 0 then Exit;
 
 {Check GPIO}
 if PWM.GPIO = GPIO_PIN_UNKNOWN then
  begin
   {Check Channel}
   case PBCM2711PWM0Device(PWM).Channel of
    0:begin
      {Set GPIO 18}
      if BCM2711PWM0SetGPIO(PWM,GPIO_PIN_18) <> ERROR_SUCCESS then Exit;
     end; 
    1:begin
      {Set GPIO 19}
      if BCM2711PWM0SetGPIO(PWM,GPIO_PIN_19) <> ERROR_SUCCESS then Exit;
     end;
    else
     begin
      Exit;
     end;   
   end;   
  end;
  
 {Start Clock}
 if PWMSoundClockStart(PWM,PWM.Frequency) <> ERROR_SUCCESS then Exit;
 
 {Memory Barrier}
 DataMemoryBarrier; {Before the First Write}
 
 {Check Channel}
 case PBCM2711PWM0Device(PWM).Channel of
  0:begin
    {PWM0 (PWM Channel 1)}
    {Enable PWEN, USEF and CLRF}
    PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).CTL:=PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).CTL or BCM2838_PWM_CTL_PWEN1 or BCM2838_PWM_CTL_USEF1 or BCM2838_PWM_CTL_CLRF1;
   end;
  1:begin
    {PWM1 (PWM Channel 2)}
    {Enable PWEN, USEF and CLRF}
    PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).CTL:=PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).CTL or BCM2838_PWM_CTL_PWEN2 or BCM2838_PWM_CTL_USEF2 or BCM2838_PWM_CTL_CLRF1;
   end;
  else
   begin
    Exit;
   end;   
 end;
 
 {Clear Status}
 PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).STA:=LongWord(-1);
 
 {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  CTL=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).CTL,8));
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  STA=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).STA,8));
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  DMAC=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).DMAC,8));
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  RNG1=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).RNG1,8));
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  DAT1=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).DAT1,8));
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  RNG2=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).RNG2,8));
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  DAT2=' + IntToHex(PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).DAT2,8));
 {$ENDIF}
 
 {Memory Barrier}
 DataMemoryBarrier; {After the Last Read} 
 
 {Return Result}
 Result:=ERROR_SUCCESS;
end; 

function PWMSoundSetFrequency(PWM:PPWMDevice;Frequency:LongWord):LongWord;
begin
 {}
 Result:=ERROR_INVALID_PARAMETER;
 
 {Check PWM}
 if PWM = nil then Exit;
 
 {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound: PWM Set Frequency (Frequency=' + IntToStr(Frequency) + ')');
 {$ENDIF}
 
 {Check Frequency}
 if Frequency = 0 then Exit;
 
 {Check Pair}
 if PBCM2711PWM0Device(PWM).Pair <> nil then
  begin
   {Check Enabled}
   if PBCM2711PWM0Device(PWM).Pair.PWM.PWMState = PWM_STATE_ENABLED then Exit;
  end;
  
 {Stop Clock}
 if BCM2711PWM0ClockStop(PWM) <> ERROR_SUCCESS then Exit;
 
 {Check Enabled}
 if PWM.PWMState = PWM_STATE_ENABLED then
  begin
   {Start Clock}
   if PWMSoundClockStart(PWM,Frequency) <> ERROR_SUCCESS then Exit;
  end; 
 
 {Update Scaler}
 PBCM2711PWM0Device(PWM).Scaler:=NANOSECONDS_PER_SECOND div Frequency;
 
 {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound:  Scaler=' + IntToStr(PBCM2711PWM0Device(PWM).Scaler));
 {$ENDIF}
 
 {Update Properties}
 PWM.Frequency:=Frequency;
 PWM.Properties.Frequency:=Frequency;
 
 {Check Pair}
 if PBCM2711PWM0Device(PWM).Pair <> nil then
  begin
   {Update Scaler}
   PBCM2711PWM0Device(PWM).Pair.Scaler:=NANOSECONDS_PER_SECOND div Frequency;
   
   {Update Properties}
   PBCM2711PWM0Device(PWM).Pair.PWM.Frequency:=Frequency;
   PBCM2711PWM0Device(PWM).Pair.PWM.Properties.Frequency:=Frequency;
  end;
  
 {Return Result}
 Result:=ERROR_SUCCESS;
end; 

function PWMSoundPlaySample(PWM:PPWMDevice;Data:Pointer;Size,ChannelCount,BitCount:LongWord):LongWord;
var
 Buffer:PByte;
 Count:LongWord;
 Value1:LongWord;
 Value2:LongWord;
 RangeBits:LongWord;
 
 Output:PLongWord;
 Samples:LongWord;
 Current:LongWord;

 DMAData:PDMAData;
begin 
 {}
 Result:=ERROR_INVALID_PARAMETER;
 
 {Check PWM}
 if PWM = nil then Exit;
 
 {$IF DEFINED(BCM2711_DEBUG) or DEFINED(PWM_DEBUG)}
 if PWM_LOG_ENABLED then PWMLogDebug(PWM,'PWM Sound: PWM Play Sample');
 {$ENDIF}
 
 {Check Parameters}
 if Size = 0 then Exit;
 if (ChannelCount <> 1) and (ChannelCount <> 2) then Exit;
 if (BitCount <> 8) and (BitCount <> 16) then Exit;
 
 ConsoleWindowWriteLn(Handle,'Playing ' + IntToStr(Size) + ' bytes on ' + IntToStr(ChannelCount) + ' channel(s) at ' + IntToStr(BitCount) + ' bits per channel');
 
 {Calculate Range Bits}
 RangeBits:=0;
 Count:=2;
 while Count < 16 do
  begin
   if PWM.Range < (1 shl Count) then
    begin
     RangeBits:=Count - 1;
     Break;
    end;
   
   Inc(Count); 
  end;
 ConsoleWindowWriteLn(Handle,'Range = ' + IntToStr(PWM.Range));
 ConsoleWindowWriteLn(Handle,'Range Bits = ' + IntToStr(RangeBits));
 
 {Get Sample Count}
 Samples:=0;
 if BitCount = 8 then
  begin
   Samples:=Size; 
   
   if ChannelCount = 1 then
    begin
     Samples:=Samples * 2; 
    end;
  end
 else if BitCount = 16 then
  begin
   Samples:=Size div 2;
   
   if ChannelCount = 1 then
    begin
     Samples:=Samples * 2; 
    end;
  end;  
 if Samples = 0 then Exit;
 
 {Allocate Output}
 Output:=DMAAllocateBuffer(Samples * SizeOf(LongWord));
 if Output = nil then Exit;
 try
  ConsoleWindowWriteLn(Handle,'Total Samples = ' + IntToStr(Samples));
  
  {Convert Sound}
  Buffer:=Data;
  Count:=0;
  Current:=0;
  while Count < Size do
   begin 
    {Get channel 1}
    Value1:=Buffer[Count];
    Inc(Count);
    if BitCount > 8 then
     begin
      {Get 16 bit sample}
      Value1:=Value1 or (Buffer[Count] shl 8); 
      Inc(Count);
      
      {Convert to unsigned}
      Value1:=(Value1 + $8000) and ($FFFF);
     end;
    
    if BitCount >= RangeBits then
    begin
     Value1:=Value1 shr (BitCount - RangeBits);
    end
    else
    begin
     Value1:=Value1 shl (RangeBits - BitCount);
    end;
    
    {Get channel 2}
    Value2:=Value1;
    if ChannelCount = 2 then
     begin
      Value2:=Buffer[Count];
      Inc(Count);
      if BitCount > 8 then
       begin
        {Get 16 bit sample}
        Value2:=Value2 or (Buffer[Count] shl 8); 
        Inc(Count);
        
        {Convert to unsigned}
        Value2:=(Value2 + $8000) and ($FFFF);
       end;
      
      if BitCount >= RangeBits then
      begin
       Value2:=Value2 shr (BitCount - RangeBits);
      end
      else
      begin
       Value2:=Value2 shl (RangeBits - BitCount);
      end;
     end;
    
    {Store Sample}
    Output[Current]:=Value1;
    Output[Current + 1]:=Value2;
    Inc(Current,2);
   end;
  
  {Get DMA data}
  DMAData:=GetMem(SizeOf(TDMAData));
  if DMAData = nil then Exit;
  FillChar(DMAData^,SizeOf(TDMAData),0);

  DMAData.Source:=Output;
  DMAData.Dest:=PBCM2711PWM0Device(PWM).Address + BCM2838_PWM_FIF1;
  DMAData.Size:=Samples * SizeOf(LongWord);
  DMAData.Flags:=DMA_DATA_FLAG_DEST_NOINCREMENT or DMA_DATA_FLAG_DEST_DREQ or DMA_DATA_FLAG_LITE;
  DMAData.StrideLength:=0;
  DMAData.SourceStride:=0;
  DMAData.DestStride:=0;
  DMAData.Next:=nil;
  
  {Enable DMA}
  PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).DMAC:=PBCM2838PWMRegisters(PBCM2711PWM0Device(PWM).Address).DMAC or BCM2838_PWM_DMAC_ENAB;
  
  {Perform DMA transfer} 
  DMATransfer(DMAData,DMA_DIR_MEM_TO_DEV,DMA_DREQ_ID_PWM1);

  {Free DMA Data}
  FreeMem(DMAData);
 finally
  DMAReleaseBuffer(Output);
 end;
 
 {Return Result}
 Result:=ERROR_SUCCESS;
end;

function read_decode_MP3file(const Filename: String):LongWord;
var
 Buffer:Pointer;
 FileStream:TFileStream;
 fnsize, fnread: integer;
 mystream:PChar;
 nlocation: Cardinal;

 nchannels, nsamples: Cardinal;
 left_ch, right_ch: PInteger;
 ix: Integer;
 pcm: mad_pcm;
 sample: Integer;

 track_timer: mad_timer_t;
 lengthms: LongInt;
 secondsx, minutesx, hoursx: integer;

begin
 Result:=ERROR_INVALID_PARAMETER;

 {Wait for SD Card}
 while not DirectoryExists ('C:\') do
  begin
   Sleep(100);
  end; 

 {Check File}
 if not FileExists(Filename) then Exit;
  
 {Open File}
 FileStream:=TFileStream.Create(Filename,fmOpenRead or fmShareDenyNone);
 fnsize := FileStream.Size;
 ConsoleWindowWriteLn(Handle, '');
 ConsoleWindowWriteLn(Handle, 'File size of ' + Filename + ' is: '  + Inttostr(fnsize) + ' bytes');
 try
  {Check Size}
  if fnsize > (100 * 1024 * 1024) then Exit;
  
  Buffer:=GetMem(fnsize);
  mystream:=GetMem(StreamSize);
  bufout:=GetMem(BufoutSize);

  try
   fnread := FileStream.Read(Buffer^,fnsize);

   if (fnread=fnsize) then
   begin
     ConsoleWindowWriteLn(Handle, 'Read MP3 File OK');

     mad_stream_buffer(umad_stream, Buffer, fnsize);
     umad_stream.error := MAD_ERROR_NONE;
     mad_timer_reset({%H-}track_timer);
     nmp3i := 0;

     ConsoleWindowWriteLn(Handle, '');
     ConsoleWindowWriteLn(Handle, 'Decoding the mp3 file...');

     {Decode frame and synthesize loop}
     while(true) do
     begin
      {Frame}
      if (mad_frame_decode(umad_frame, umad_stream)<>0) then
       begin
         if (umad_stream.error = MAD_ERROR_BUFLEN) then break;
         if Not(MAD_RECOVERABLE(umad_stream.error)) then Break;
       end;
       mad_timer_add(track_timer, umad_frame.header.duration);
       mad_synth_frame(umad_synth,umad_frame);

       pcm := umad_synth.pcm;
       nchannels := pcm.channels;
       nsamples := pcm.length;
       left_ch := pcm.samples[0];
       right_ch := pcm.samples[1];

       for ix := 0 to nsamples - 1 do
       begin
         sample := scale(left_ch^);
         Inc(left_ch);
         mystream[(4 * ix)] := Char((sample shr 0) and $FF);
         mystream[(4 * ix) + 1] := Char((sample shr 8) and $FF);
         if nchannels = 2 then
         begin
           sample := scale(right_ch^);
           Inc(right_ch);
         end;
         mystream[(4 * ix) + 2] := Char((sample shr 0) and $FF);
         mystream[(4 * ix) + 3] := Char((sample shr 8) and $FF);
       end;

       nlocation := (1152 * 4 * nmp3i);
       Inc(nmp3i);
       Move(mystream[0], bufout[nlocation], StreamSize);

     end;

     channel_count := umad_synth.pcm.channels;
     samplerate := umad_synth.pcm.samplerate;
     bit_count := SOUND_BITS;

     lengthms := mad_timer_count(track_timer, MAD_UNITS_MILLISECONDS);
     secondsx := lengthms div 1000 mod 60;
     minutesx := (lengthms div (1000 * 60)) mod 60;
     hoursx := (lengthms div (1000 * 60 * 60)) mod 24;

     ConsoleWindowWriteLn(Handle, '');
     ConsoleWindowWriteLn(Handle, 'Duration: ' + Format('%0.2d:%0.2d:%0.2d',[hoursx,minutesx,secondsx]));
     ConsoleWindowWriteLn(Handle, 'BitRate: ' + Inttostr(umad_frame.header.bitrate) + ' bps');
     ConsoleWindowWriteLn(Handle, 'Number channels: ' + Inttostr(channel_count));
     ConsoleWindowWriteLn(Handle, 'SampleRate: ' + Inttostr(samplerate) + ' hz');
     ConsoleWindowWriteLn(Handle, '');

     {Return Success}
     Result := ERROR_SUCCESS;
   end;


  finally
   FreeMem(Buffer);
   FreeMem(mystream);
  end;  
 finally
  FileStream.Free;
 end;
 
 {Return Result}
 Result:=ERROR_SUCCESS;
end;

function pwmsound_play_MP3file(PWM:PPWMDevice):LongWord;
begin
 Result:=ERROR_INVALID_PARAMETER;

 {Check PWM}
 if PWM = nil then Exit;

 try
  Result:=PWMSoundPlaySample(PWM,bufout, 1152 * 4 * nmp3i, channel_count, bit_count);
 finally
  FreeMem(bufout);
 end;

 {Return Result}
 Result:=ERROR_SUCCESS;
end;

begin
 {Create a console window and display a welcome message}
 Handle:=ConsoleWindowCreate(ConsoleDeviceGetDefault,CONSOLE_POSITION_FULL,True);
 ConsoleWindowWriteLn(Handle,'MP3 Player with Ultibo and libmad');
 ConsoleWindowWriteLn(Handle,'Make sure you have a the Raspberry Pi audio jack connected to the AUX input of an amplifier, TV or other audio device');

 {Initialize MAD structures}
 mad_stream_init({%H-}umad_stream);
 mad_synth_init({%H-}umad_synth);
 mad_frame_init({%H-}umad_frame);

 {Read and decode MP3 File}
 resMP3 := read_decode_MP3file('test.mp3');

 {First locate the PWM devices
 
  The Raspberry Pi 4 has four PWM channels and the two which can be used 
  for playing sound will normally end up with the names PWM2 and PWM3 when
  the driver is included in an application.

  You could also use PWMDeviceFindByDescription() here and use the value returned
  by calling PWMGetDescription and passing the Id and Channel parameters like this 
  
   PWMDeviceFindByDescription(PWMGetDescription(1,0));
   PWMDeviceFindByDescription(PWMGetDescription(1,1));
  
  which would be accurate even if the numbering of the devices in Ultibo changed.}

 PWM0Device:=PWMDeviceFindByName('PWM2');
 PWM1Device:=PWMDeviceFindByName('PWM3');
 if (PWM0Device <> nil) and (PWM1Device <> nil) and (resMP3=ERROR_SUCCESS) then
  begin

   PWM0Device.DeviceStart:=PWMSoundStart;
   PWM0Device.DeviceSetFrequency:=PWMSoundSetFrequency;
   PWM1Device.DeviceStart:=PWMSoundStart;
   PWM1Device.DeviceSetFrequency:=PWMSoundSetFrequency;
   
   {Setup PWM device 0}
   {Set the GPIO}
   PWMDeviceSetGPIO(PWM0Device,GPIO_PIN_40);
   {Set the range} 
   PWMDeviceSetRange(PWM0Device,(CLOCK_RATE + (samplerate div 2)) div samplerate);
   {And the mode to PWM_MODE_BALANCED}
   PWMDeviceSetMode(PWM0Device,PWM_MODE_BALANCED);
   {Finally set the frequency}
   PWMDeviceSetFrequency(PWM0Device,CLOCK_RATE);

   {Setup PWM device 1}
   {Use exactly the same settings as PWM0 except the GPIO is 41}
   PWMDeviceSetGPIO(PWM1Device,GPIO_PIN_41);
   PWMDeviceSetRange(PWM1Device,(CLOCK_RATE + (samplerate div 2)) div samplerate);
   PWMDeviceSetMode(PWM1Device,PWM_MODE_BALANCED);
   PWMDeviceSetFrequency(PWM1Device,CLOCK_RATE);

   ConsoleWindowWriteLn(Handle,'Range = ' + IntToStr(PWM0Device.Range));
   
   {Start the PWM devices}
   if (PWMDeviceStart(PWM0Device) = ERROR_SUCCESS) and (PWMDeviceStart(PWM1Device) = ERROR_SUCCESS) then
    begin

     if pwmsound_play_MP3file(PWM0Device) <> ERROR_SUCCESS then
      begin
       ConsoleWindowWriteLn(Handle,'Error: Failed to play MP3 sound file');
      end
     else
      begin
       ConsoleWindowWriteLn(Handle,'Finished playing MP3 sound sample');
      end;      
     
     {Stop the PWM devices}
     PWMDeviceStop(PWM0Device);
     PWMDeviceStop(PWM1Device);

     {Release MAD structures}
     mad_stream_init(umad_stream);
     mad_synth_init(umad_synth);
     mad_frame_init(umad_frame);

    end
   else
    begin
     ConsoleWindowWriteLn(Handle,'Error: Failed to start PWM devices 0 and 1');
    end;
  end
 else
  begin
   ConsoleWindowWriteLn(Handle,'Error: Failed to locate PWM devices 0 and 1');
  end;  
  
 {Turn on the LED to indicate completion} 
 ActivityLEDEnable;
 ActivityLEDOn;
 
 {Halt the thread if we return}
 ThreadHalt(0);
end.
