#!/usr/bin/perl
#
# perlモジュール管理スクリプト
# デフォルト動作: パラメータのパターンにマッチしたモジュールの名前を出力する
# オプション
#  -v --version : バージョン番号を出力する
#  -d --delete  : マッチしたモジュールを削除する 
#  -y --yes     : 削除時に確認しない

use Getopt::Long;
use ExtUtils::Installed;
use ExtUtils::Install;

my $pattern, $inst;
my $opt_version, $opt_delete, $opt_delete_yes;
my $outstr;
my $query;

GetOptions(
    'version' =>\$opt_version,
    'delete' =>\$opt_delete,
    'yes' => \$opt_delete_yes,
    );

$pattern = '';
if (($pattern = $ARGV[$#ARGV]) !~ /^\-/) {
    chomp $pattern;
}
$inst = ExtUtils::Installed->new();
foreach $mod (sort $inst->modules()) {
    if ($opt_version > 0) {
	$outstr = sprintf("%-25s  %s\n", $mod, $inst->version($mod));
    } else {
	$outstr = sprintf("%-s\n", $mod);
    }
    if ($mod =~ $pattern) {
	if ($opt_delete >0) {
	    if ($opt_delete_yes <= 0) {
		printf "uninstall $mod (Y/N) ";
		$query = <STDIN>;
		if ($query =~ /[Yy]/) {
		    uninstall($inst->packlist($mod)->packlist_file());
		    printf "uninstalled $mod\n";
		}
	    } else {
		uninstall($inst->packlist($mod)->packlist_file());
		printf "uninstalled $mod\n";
	    }
	} else {
	    print $outstr;
	}
    }
}
