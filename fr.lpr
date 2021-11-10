{
    Copyright (c) 2020 by Florian Klaempfl

    Helper to flash and run a program on an esp32 while collecting the output

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}
{ $define DEBUG}
{$define esp32}
{ $define esp8266}
{ $define FLASH_BOOTLOADER}
program fr;

uses
  sysutils,serial,baseunix,termio,unix,syscall;

const
  timeout = 20; { seconds }
  timeoutport = 120;

const
  TCGETS2 = $802C542A;
  TCSETS2 = $402C542B;
  BOTHER  = &10000;
  syscall_nr_renameat2          = 316;
  RENAME_NOREPLACE = 1;
type
  {$PACKRECORDS C}
  Termios = record
    c_iflag,
    c_oflag,
    c_cflag,
    c_lflag  : cardinal;
    c_line   : char;
    c_cc     : array[0..19-1] of byte;
    c_ispeed,
    c_ospeed : cardinal;
  end;


var
  s : shortstring;
  handle: TSerialHandle;
  status: LongInt;
  tios : Termios;
  progbase, line, portstr, filename, lib_path: String;
  exitcode : longint;
  code : word;
  port: Integer;
  idf_path, lockfilename: String;
  testfile: Text;
  starttime: QWord;
begin
  if paramcount<>1 then
    begin
      writeln('Program missing');
      halt(1);
    end;
  idf_path:=GetEnvironmentVariable('IDF_PATH');
  progbase:=GetEnvironmentVariable('ESP32_PROGSTART');
  if progbase='' then
    progbase:='0x10000';
  port:=0;
  filename:=GetTempFileName(GetTempDir(true),'esptest');
  assign(testfile,filename);
  rewrite(testfile);
  close(testfile);
  while true do
    begin
      portstr:='/dev/ttyUSB'+IntToStr(port);
      if FileExists(portstr) then
        begin
          lockfilename:=GetTempDir(true)+'/esptestlock_ttyUSB'+IntToStr(port);
          if do_syscall(syscall_nr_renameat2,AT_FDCWD,TSysParam(filename),AT_FDCWD,TSysParam(lockfilename),RENAME_NOREPLACE)=0 then
            break;
          sleep(10);
          { if a port is locked too long, unlock it, either we or another
            instance can reuse it }
          if (Now-FileDateToDateTime(FileAge(lockfilename)))*24*3600>timeoutport then
            begin
              writeln('Port locked for too long, deleting lock');
              DeleteFile(lockfilename);
            end;
        end;
      inc(port);
      if port>7 then
        port:=0;
    end;
{$ifdef DEBUG}
  writeln('Using port: ',portstr);
{$endif DEBUG}

{$ifdef esp8266}
  lib_path:=GetEnvironmentVariable('HOME')+'/esp/xtensa-lx106-elf-libs';
  if ExecuteProcess(idf_path+'/components/esptool_py/esptool/esptool.py',
    '--chip esp8266 --port "'+portstr+'" --baud 921600 --before "default_reset" --after "hard_reset" '+
    'write_flash -z --flash_mode "dio" --flash_freq "40m" --flash_size "2MB" '+
{$ifdef FLASH_BOOTLOADER}
    '0x0 '+lib_path+'/bootloader.bin 0x8000 '+lib_path+'/partitions_singleapp.bin'+
{$endif FLASH_BOOTLOADER}
    progbase+' '+paramstr(1)+'.bin ')<>0 then
    begin
      writeln('Flashing not successfull');
      DeleteFile(lockfilename);
      halt(1);
    end;
{$endif esp8266}

{$ifdef esp32}
  lib_path:=GetEnvironmentVariable('HOME')+'/esp/xtensa-esp32-elf-libs';
  if ExecuteProcess(idf_path+'/components/esptool_py/esptool/esptool.py','-p '+portstr+' -b 921600 --before default_reset --after hard_reset --chip esp32  write_flash --flash_mode dio --flash_size detect --flash_freq 40m '+
{$ifdef FLASH_BOOTLOADER}
    '0x1000 '+lib_path+'/bootloader.bin 0x8000 '+lib_path+'/partition-table.bin '+
{$endif FLASH_BOOTLOADER}
    progbase+' '+paramstr(1)+'.bin')<>0 then
    begin
      writeln('Flashing not successfull');
      DeleteFile(lockfilename);
      halt(1);
    end;
{$endif esp32}

  handle:=SerOpen(portstr);

{$ifdef esp8266}
  SerSetParams(handle,9600,8,NoneParity,1,[]);

  { ESP8266 uses non-standard baud rate of 74880 }
  FpIOCtl(handle,TCGETS2,@tios);
  with tios do
    begin
      c_cflag:=c_cflag and not(CBAUD);
      c_cflag:=c_cflag or BOTHER;
      c_ispeed:=74880;
      c_ospeed:=74880;
    end;

  if not(FpIOCtl(handle,TCSETS2,@tios)=0) then
    begin
      writeln('Cannot set serial speed to 74880, exiting');
      DeleteFile(lockfilename);
      halt(1);
    end;
{$endif esp8266}

{$ifdef esp32}
  { ESP32 uses standard baud rate of 115200 }
  SerSetParams(handle,115200,8,NoneParity,1,[]);
{$endif esp32}

  { reset ESP }
  SerSetDTR(handle,false);
  SerSetRTS(handle,true);
  SerSetRTS(handle,false);

  { clean serial input buffer, it might contain garbage }
  SerFlushInput(handle);

  starttime:=GetTickCount64;

  line:='';
  while true do
    begin
      status:=SerRead(handle,s[1],1);
      if status>0 then
        begin
          write(s[1]);
          if s[1]=#10 then
            begin
              if copy(line,1,29)='_haltproc called, exit code: ' then
                break;
              { crash? then halt with an error }
              if (copy(line,1,21)='Guru Meditation Error') or (copy(line,1,12)='Rebooting...') then
                begin
                  DeleteFile(lockfilename);
                  halt(1);
                end;
              line:='';
            end
          else
            line:=line+s[1];
        end
      else
        sleep(10);
      if GetTickCount64-starttime>timeout*1000 then
        begin
          writeln('Timeout, exiting');
          DeleteFile(lockfilename);
          halt(1);
        end;
    end;
  val(Copy(line,30,length(line)-31),exitcode,code);
  if code<>0 then
    begin
      writeln(code);
      writeln('Exit code not recognized');
      exitcode:=1;
    end;
  SerSync(handle);
  SerFlushOutput(handle);
  SerClose(handle);
  DeleteFile(lockfilename);
  halt(exitcode);
end.

