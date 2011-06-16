#!/usr/bin/perl
# DS2480B + DS18B20 温度測定プログラム Ver. 1.3 2010/05/25
#
#  Options
#  -r 各センサのROMIDを出力
#  -p parasite powerd(寄生電源)モード
#  -s 各センサのスクラッチパッドの内容を出力
#  -b ROM Search時の検索アクセラレータ出力をROMIDデータと
#     不一致データに分けて2進表示

use Device::SerialPort qw( :PARAM :STAT 0.07 );
use constant DEV => "/dev/ttyUSB0"; # 対象となるシリアルデバイスの名前に設定

# 入力オプション解析用
use Getopt::Long;
my $opt_romid, $opt_parastie, $opt_scpad, $opt_dump, $opt_bitdump;
GetOptions(
    'romid'    => \$opt_romid,
    'parastie' => \$opt_parastie,
    'scpad'    => \$opt_scpad,
    'bitdump'  => \$opt_bitdump,
);

use constant {
    BreakPulse    => 4,
    Sleep2Micro   => 0.002,
    Sleep100Mil   => 0.1,
    Sleep500Mil   => 0.5,
    Sleep760Mil   => 0.76,
    ID_RETRY      => 3,
    TEMPER_ERROR  => -256,
# DS2480Bのコマンド, 定数
    SIF_PULSE1000     => 0x3b,
    SIF_PULSE500      => 0x39,
    SIF_PULSE260      => 0x37,
    SIF_ARM_STRPULSE  => 0xef,
    SIF_DARM_STRPULSE => 0xed,
    SIF_TERM_PULSE    => 0xf1,
    SIF_DATA          => 0xe1,
    SIF_COMMAND       => 0xe3,
    SIF_ACCON         => 0xb1,
    SIF_ACCOFF        => 0xa1,
    SIF_RST1W         => 0xc1,
    SEARCHDATA_SIZE   => 16,
# 1-Wireのfunction, 定数
    CMD_CONV     => 0x44,
    CMD_RDPAD    => 0xbe,
    CMD_WRPAD    => 0x4e,
    SCPAD_SIZE   => 9,
# ROM COMMAND
    ROM_SEARCH   => 0xf0,
    ROM_MATCH    => 0x55,
    ROM_SKIP     => 0xcc,
    ROMID_SIZE   => 8,
# TEST & Configure command
    TEST_PDSRC   => 0x11, 
    TEST_W1LT    => 0x45,
    TEST_DSO     => 0x51,
    TEST_RDBR    => 0x0f,
    TEST_SBWR    => 0x91,
    RET_SBWR     => 0x93,
    BAUD9600     => 0, 
    Bit0_MASK    => 0xfe,
    BYTE_MASK    => 0xff,
};

# crc table
@dscrc_table = (
        0, 94,188,226, 97, 63,221,131,194,156,126, 32,163,253, 31, 65,
      157,195, 33,127,252,162, 64, 30, 95,  1,227,189, 62, 96,130,220,
       35,125,159,193, 66, 28,254,160,225,191, 93,  3,128,222, 60, 98,
      190,224,  2, 92,223,129, 99, 61,124, 34,192,158, 29, 67,161,255,
       70, 24,250,164, 39,121,155,197,132,218, 56,102,229,187, 89,  7,
      219,133,103, 57,186,228,  6, 88, 25, 71,165,251,120, 38,196,154,
      101, 59,217,135,  4, 90,184,230,167,249, 27, 69,198,152,122, 36, 
     248,166, 68, 26,153,199, 37,123, 58,100,134,216, 91,  5,231,185,
      140,210, 48,110,237,179, 81, 15, 78, 16,242,172, 47,113,147,205,
       17, 79,173,243,112, 46,204,146,211,141,111, 49,178,236, 14, 80,
      175,241, 19, 77,206,144,114, 44,109, 51,209,143, 12, 82,176,238,
       50,108,142,208, 83, 13,239,177,240,174, 76, 18,145,207, 45,115,
      202,148,118, 40,171,245, 23, 73,  8, 86,180,234,105, 55,213,139,
       87,  9,235,181, 54,104,138,212,149,203, 41,119,244,170, 72, 22,
      233,183, 85, 11,136,214, 52,106, 43,117,151,201, 74, 20,246,168,
      116, 42,200,150, 21, 75,169,247,182,232, 10, 84,215,137,107, 53
);

# init Serial port
sub init_serial{
    my $port = Device::SerialPort->new(DEV)
	|| die "Can't open DEV: $!\n";;

    $port->read_char_time(10);
    $port->read_const_time(100);
    $port->baudrate(9600);
    $port->databits(8);
    $port->parity("none");
    $port->handshake("none");
    return $port;
}

sub reset2480b {
    my $port = $_[0];
    $port->pulse_break_on(BreakPulse);      # Reset 2480B
    select(undef,undef,undef, Sleep500Mil); # Wait for 2480B
}

sub reset1wire {
    my $port = $_[0];
    my $out, $count;
    my @ret;

    $out = pack "c", SIF_RST1W;
    $count = $port->write($out);         # reset w1-bus
    if ($count == 0) {
	print "Can't RESET";
	exit 1;
    }
    select(undef,undef,undef, Sleep100Mil); # Wait for 2480B
    ($count, $out) = $port->read(1);
    @ret = unpack "c", $out;
    return $ret[0] & 0xff;
}

sub write1 {
    my $port = $_[0];
    my $wdata = $_[1];
    my $out,$count,$ret;

    $out = pack "c", $wdata;
    $count = $port->write($out);
    if ($count < 1) {
	printf("Fail write DS2380B %d\n",$count);
	exit 1;
    }
    return 1;
}

sub data_writeread1 {
    my $port = $_[0];
    my $wdata = $_[1];

    if ($wdata == SIF_COMMAND) {
	    writeread1($port, $wdata);
    }
    $ret=writeread1($port, $wdata) ;
    return $ret;
}

sub data_write1 {
    my $port = $_[0];
    my $wdata = $_[1];

    if ($wdata == SIF_COMMAND) {
	    write1($port, $wdata);
    }
    $ret=write1($port, $wdata);
    return $ret;
}

sub writeread1 {
    my $port = $_[0];
    my $wdata = $_[1];
    my $out,$count;
    my @ret;

    $out = pack "c", $wdata;
    $count = $port->write($out);
    if ($count < 1) {
	printf("Fail write DS2380B %d\n",$count);
	exit 1;
    } else {
	$count = 0;
	while($count == 0) { 
	    ($count, $out) = $port->read(1);
	    @ret = unpack "c", $out;
	}
    }
    return $ret[0] & BYTE_MASK;
}

# DS18B20

sub convert_all {
    my $port;
    my $presence,$i,$count;

    $port = $_[0];

    write1($port, SIF_COMMAND);  # set command mode
    $presence = reset1wire($port);
    write1($port, SIF_DATA);     # set data mode
    data_writeread1($port,ROM_SKIP);
    data_writeread1($port,CMD_CONV);
    write1($port, SIF_COMMAND);  # set command mode
    select(undef,undef,undef, Sleep760Mil); 
    $presence = reset1wire($port);
    return 1;
}

sub convert_all_strong_pulse {
    my $port;
    my $presence,$count,$ret;
    
    $port = $_[0];

    write1($port, SIF_COMMAND);                  # set command mode
    $ret = writeread1($port, SIF_PULSE1000);     # Strong Pullup Duration 1048ms
    $presence = reset1wire($port);
    write1($port, SIF_DATA);                     # set data mode
    data_writeread1($port,ROM_SKIP);             # Skip ROM
    write1($port, SIF_COMMAND);                  # set command mode
    write1($port, SIF_ARMSTRPULSE);              # Arm Strong Pullup
    writeread1($port, SIF_TERM_PULSE);           # Terminate Pulse
    write1($port, SIF_DATA);                     # set data mode
    data_writeread1($port,CMD_CONV);
    write1($port, SIF_COMMAND);                  # set command mode
    writeread1($port, SIF_DARM_STRPULSE);        # DisArm Strong Pullup
    select(undef,undef,undef, Sleep760Mil); 
    writeread1($port, SIF_TERM_PULSE);           #Terminate Pulse

    $presence = reset1wire($port);
    return 1;
}

# read scratchpad
sub read_scratchpad {
    my $port;
    my @id;  # 8byte(64bits ID)
    my $presence, $i, $count;
    my @scpad,$out,@tmp;

    ($port, @id) = @_;
    write1($port, SIF_COMMAND);  # set command mode
    $presence = reset1wire($port);
    write1($port, SIF_DATA);     # set data mode
    data_writeread1($port,ROM_MATCH);
    for($i = 0; $i < ROMID_SIZE; $i++) {
 	data_writeread1($port, $id[$i]);
    }
    data_writeread1($port,CMD_RDPAD);
    select(undef,undef,undef, Sleep2Micro); # Wait for 2480B
    for($i = 0; $i < 9; $i++) {
	$out = writeread1($port, 0xff);
	$scpad[$i] = $out ;
    }
    write1($port, SIF_COMMAND);  # set command mode
    $presence = reset1wire($port);
    return @scpad;
 }    

# DS2480B detect & configuration 
sub detect {
    my $port = $_[0];
    my $done = 0;
    my $count,$out;

    reset1wire($port);
    # test DS2480B
    # Configuration test Write PDSRC
    if ((TEST_PDSRC & Bit0_MASK) != ($out = writeread1($port, TEST_PDSRC))) {
	printf("config PDSRC fail %0x\n",$out);
	exit 1;
    }
    # Configuration test Write W1LT
    if ((TEST_W1LT & Bit0_MASK)  != ($out = writeread1($port, TEST_W1LT))) {
	printf("config W1LT fail %0x\n", $out);
	exit 1;
    }
    # Configuration test Write DSO/W0RT
    if ((TEST_DSO & Bit0_MASK) != ($out = writeread1($port, TEST_DSO))) {
	printf("config DSO/W0RT fail %0x\n", $out);
	exit 1;
    }
    # Configuretion test Read Baud Rate
    if ( BAUD9600 != ($out = writeread1($port, TEST_RDBR))) {
	# 9600ボーの設定ではない?
	printf("config Read Baud Rate fail %0x\n", $out);
	exit 1;
    }
    # Single bit  write test
    if ( RET_SBWR != ($out = writeread1($port, TEST_SBWR))) {
	printf("Single bit write test  fail %0x\n", $out);
	exit 1;
    }
    reset1wire($port);
}

sub id_nibble {
    my $inbyte = $_[0];
    my $out, $i;

    $out = 0;
    for ($i = 0; $i < 4; $i ++) {
	$out <<=1;
	$out |= 1 if ($inbyte & 0x80);
	$inbyte <<= 2;
    }
    return $out;
}

sub id_pick {
    my @data = @_;
    my $i,$j;
    my @id;

    for ($i = 0; $i < SEARCHDATA_SIZE; $i+=2) {
	$id[$i/2] = id_nibble($data[$i])+(id_nibble($data[$i+1])<<4);
    }
    return @id;
}

sub zero_fill_index {
    my $wpos, $bpos;
    my @search_data;
    my $i,$j;
    my $r_mask = 2;

    ($wpos,$bpos,@search_data) = @_;
    $r_mask <<= $bpos*2;
    for ($j = $bpos;  $j < 4; $j++, $r_mask <<= 2) {
	$search_data[$wpos] &= (~$r_mask);
    }
    for ($i = $wpos+1; $i < SEARCHDATA_SIZE; $i ++) {
	for ($r_mask = 2, $j = 0;  $j < 4; $j++, $r_mask <<= 2) {
	    $search_data[$i] &= (~$r_mask);
	}
    }
    return @search_data;
}

sub next_search_data {
# 検索アクセラレータの出力データから次の検索アクセラレータ入力データを作る
# 戻り値の最初のデータ(不一致点)が負の場合は検索終了を意味する

# 入力: 検索アクセラレータの出力
# 出力: $lastb_search - LASTB 次に検索を開始する不一致点(0〜63)
#     : @out  - 次の検索アクセラレータ入力データ  
    my @search_data;
    my $i,$j;
    my $wpos, $bpos;
    my $match_bitmap, $bmask;
    my @out;
    my $lastbp = 0;
    my $BYTE_D_MASK = 0x55;
    my $BYTE_R_MASK = 0xaa;

    @search_data = @_;

    for ($i = 0; $i < SEARCHDATA_SIZE; $i++) {
	# バイト単位で不一致ビットが1でかつROM IDの対応するビットが0のビットがあるか調べる
	$match_bitmap =(($search_data[$i] & $BYTE_D_MASK) << 1)&(~($search_data[$i] & $BYTE_R_MASK));
	if ($match_bitmap) {
	    # 最大不一致ビットが存在する可能性のあるバイトブロック
	    for ($bmask = 2, $j = 0; $j< 4; $j++, $bmask<<=2) {
		if ( $match_bitmap & $bmask) {
		    # 最大不一致ビットの候補
		    $lastbp = $i*4+$j;
		}
	    }
	}
    }
    if ($lastbp > 0) {
	$wpos = int($lastbp / 4);
	$bpos = $lastbp % 4;
	@out = zero_fill_index($wpos, $bpos, @search_data);
	$r_mask = (2 << (2*$bpos));
	$out[$wpos] |= $r_mask; # rmを1にセット
	return ($lastbp+1, @out);
    } else {
	return (-1, @serch_data);
    }
}

sub bitdump_search_data {
    my @search_data = @_;
    my $i, $j, $mask;

    printf("direct data: ");
    for ($i=0; $i < SEARCHDATA_SIZE; $i++){
	for ($mask = 2, $j = 0 ; $j < 4; $j++) {
	    if (($mask & (BYTE_MASK & $search_data[$i])) == 0) {
		printf("0");
	    } else {
		printf("1");
	    }
	    $mask <<= 2;
	}
    }
    printf("\numatch data: ");
    for ($i=0; $i < SEARCHDATA_SIZE; $i++){
	for ($mask = 1, $j = 0 ; $j < 4; $j++) {
	    if (($mask & (BYTE_MASK & $search_data[$i])) == 0) {
		printf("0");
	    } else {
		printf("1");
	    }
	    $mask <<= 2;
	}
    }
    printf("\n");
}

sub search_acc{
    my $port;
    my @search_data ;
    my $out,$i,$tmp;
    my @ret, @acc_out;

    ($port , @search_data) = @_;
    reset1wire($port);
    select(undef,undef,undef, Sleep2Micro); # Wait for 2480B
    write1($port, SIF_DATA);     # data mode
    writeread1($port, ROM_SEARCH);   # Search ROM cmd
    write1($port, SIF_COMMAND);  # command mode
    write1($port, SIF_ACCON);    # Search Accelerarator On 
    write1($port, SIF_DATA);     # data mode
    for ($i=0; $i < SEARCHDATA_SIZE; $i++){
	$out = data_write1($port, $search_data[$i]);
    }
    write1($port, SIF_COMMAND);  # command mode
    write1($port, SIF_ACCOFF);   # Search Accelerarator Off
    write1($port, SIF_DATA);     # data mode
     for ($i=0; $i < SEARCHDATA_SIZE; $i++){
 	($tmp, $out) = $port->read(1);
 	@ret = unpack "c", $out;
 	$acc_out[$i] = $ret[0] & 0xff;
     }
    id_pick(@acc_out);
    $out = write1($port, SIF_COMMAND);          # command mode
    reset1wire($port);
    return @acc_out;
}

sub search_ids{
    my $port = $_[0];
    my $i;
    my @id;
    my $devices = 0;
    my @ids;
    my @outbound_acc;
    my $lastb = 999;

    reset1wire($port);
    for($i = 0; $i < SEARCHDATA_SIZE; $i++) {
	$outbound_acc[$i] = 0x00;
    }

    while($lastb > 0) { 
	@outbound_acc = search_acc($port, @outbound_acc);
	if ($opt_bitdump > 0) {
	    bitdump_search_data(@outbound_acc);
	}
	@id = id_pick(@outbound_acc);
	for($i = 0; $i < 8;  $i++) {
	    $ids[$devices]->[$i] = $id[$i];
	}
	($lastb,@outbound_acc) = next_search_data(@outbound_acc);
	$devices++;
    }
    return ($devices,@ids)
}

sub dscrc8 {
    my $utilcrc8 = 0;
    my $i;

    ($size, @data) = @_;
    for ($i = 0; $i < $size; $i++) {
	$utilcrc8 = $dscrc_table[$utilcrc8 ^ ($data[$i] & BYTE_MASK)];
    }
    return $utilcrc8;
}

sub chk_romid {
    my @idmat;
    my $devices;
    my $i,$j, @temp;

    ($devices, @idmat) = @_;
    for ($i = 0; $i < $devices; $i++){
	for($j = 0; $j < ROMID_SIZE; $j++) {
	    $temp[$j] = $idmat[$i][$j];
	}
	$crc = dscrc8(7, @temp);
	if ($crc != $idmat[$i][$j-1]) {
	    return 0;
	}
    }
    return $crc;
}    

sub chk_scpad {
    my @scpad = @_;
    my $devices;
    my $i;

    if ($opt_scpad > 0) {
	print "Scratch pad:";
	for($i = 0; $i < SCPAD_SIZE; $i++) {
	    printf(" %02x",$scpad[$i]);
	}
	printf("\n");
    }
    $crc = dscrc8(8, @scpad);
    if ($crc != $scpad[SCPAD_SIZE-1]) {
	return 0;
    }
    return $crc;
}    

sub read_temper {
    my @scpad = @_;
    my $devices;
    my $i;

    if (! chk_scpad(@scpad)) {
	return TEMPER_ERROR;
    } else {
	return ($scpad[0]+$scpad[1]*256)/16;
    }
}

my $port = init_serial();
my @scpad, @idr, $dev;
my $temper, $i;

print "serial_init done\n";

reset2480b($port);
print "reset 2480B done\n";
detect($port);
print "configure 2480B\n";


for ($i = 0; $i < ID_RETRY; $i++) {
    ($devices, @ids) = search_ids($port);
    if (chk_romid($devices, @ids) > 0) {
	last;
    }
}
die "ROMID CRC error" if ($i == ID_RETRY);

print "Devices num: $devices\n";

if ($opt_romid > 0) {
    for ($i = 0; $i < $devices; $i++){
	printf("Device %d ROMID: ",$i);
	for($j = 0; $j < ROMID_SIZE; $j++) {
	    printf("%02x",$ids[$i][$j]);
	    if ($j == 0 || $j == 6) {
		printf("-");
	    }
	}
	printf("\n");
    }
}

if ($opt_parastie > 0) {
    print "Parastie Mode\n";
    convert_all_strong_pulse($port);
} else {
    convert_all($port);
}

write1($port, SIF_COMMAND);  # command mode
reset1wire($port);

for ($dev = 0; $dev < $devices; $dev++) {
   for ($i = 0; $i < 8; $i ++) {
 	$idr[$i] = $ids[$dev]->[$i];
    }
   @scpad = read_scratchpad($port, @idr);

   if (TEMPER_ERROR != ($temper = read_temper(@scpad))){
       printf("[Sensor: %d] %5.1f (C)\n",$dev,$temper);
   } else {
       printf("\t ScratchPad CRC error!\n");
   }
}

# Copyright (C)2010 by Yoshiaki Uchikawa
# 利用許諾条件
#
# 上記著作権者は, Free Software Foundation によって公表されている 
# GNU General Public License の Version 2またはそれ以降のバージョン
# に記述されている条件か, 以下の条件のいずれかを満たす場合に限り, 
# 本ソフトウェア(本ソフトウェアを改変したものを含む. 以下同じ)を使用
# ・複製・改変・再配布(以下,利用と呼ぶ)することを無償で許諾する.
#
#(1) 本ソフトウェアを利用する場合には, 上記の著作権表示, この利用条件
#    および下記の無保証規定が, ソースコードまたはドキュメントにそのま
#    まの形で含まれていること.
#
#(2) 本ソフトウェアの利用により直接的または間接的に生じるいかなる損害
#    からも, 上記著作権者を免責すること.
#
#本ソフトウェアは, 無保証で提供されているものである. 上記著作権者は,
#本ソフトウェアに関して, その適用可能性も含めて, いかなる保証も行わ
#ない.  また，本ソフトウェアの利用により直接的または間接的に生じたい
#かなる損害に関しても, その責任を負わない.
