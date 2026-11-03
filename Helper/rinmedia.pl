# Nạp librinmedia.dylib vào perl của Apple rồi chạy hàm rn_main (xem rinmedia.m).
use strict;
use warnings;
use DynaLoader;

my $lib = shift @ARGV or die "thiếu đường dẫn thư viện\n";
my $handle = DynaLoader::dl_load_file($lib, 0) or die "không nạp được thư viện: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($handle, "rn_main") or die "không thấy rn_main: " . DynaLoader::dl_error() . "\n";
my $sub = DynaLoader::dl_install_xsub("main::rn_main", $sym);
&$sub();
