#!/usr/bin/perl -I../

#==========================================================================
# SWITCH PORTS ACTIVITY MONITOR -- BACKEND
# """"""""""""""""""""""""""""""""""""""""
# 2009-2011 Borek Lupomesky <borek.lupomesky@vodafone.com>
#
# Backend script for client-side JavaScript.
#==========================================================================

use CGI;
use SPAMv2;
use strict;
use integer;
use feature "switch";


#==========================================================================
# Backend for Patch Panel Map v2.
#==========================================================================

sub backend_ppmap
{
  my $q = shift;
  
  my $id = $q->url_param('id');     
  $id =~ /^(...)(...)$/;  
  my ($site, $room) = (lc($1), uc($2));
  my @qry;
  
  if($site && $room) {
    my $i = 0;
    my ($col_min, $col_max, $row_min, $row_max);
  

    my $dbh = dbconn('spam');
    my $q2 = qq{SELECT * FROM v_ppmap WHERE site = '$site' AND room = '$room' ORDER BY col, row, pos};
    my $sth = $dbh->prepare($q2);
    if($sth->execute()) {
      while(my @a = $sth->fetchrow_array()) {
       $qry[$i++] = \@a;
        $col_min = $a[0] if !defined($col_min) || $col_min > $a[0];
        $col_max = $a[0] if !defined($col_max) || $col_max < $a[0];
        $row_min = $a[1] if !defined($row_min) || $row_min > $a[1];
        $row_max = $a[1] if !defined($row_max) || $row_max < $a[1];
      }
    
      print "{\n";
      printf(qq<"status" : "ok",\n>);
      printf(qq<"lines" : %d,\n>, $i);
      printf(qq<"col_min" : %d,\n>, $col_min);
      printf(qq<"col_max" : %d,\n>, $col_max);
      printf(qq<"row_min" : %d,\n>, $row_min);
      printf(qq<"row_max" : %d,\n>, $row_max);
      print qq<"data" : [\n>;
      for(my $j = 0; $j < $i; $j++) {
        printf(qq<[%d,%d,%d,"%s","%s","%s","%s",%d,%d,%d,%d]%s\n>,@{$qry[$j]}[0..10], $j == ($i-1) ? '' : ',');
      }
      print qq<]\n}\n>;
    } else {
      printf(qq<{\n"status" : "error",\n"errmsg" : "%s (%s)"\n}\n>, "Cannot query database", $sth->errstr);
    }
  }
}


#==========================================================================
# Backend for Patch Panel Map v2.
#==========================================================================

sub backend_patching_activity
{
  my $q = shift;
  my ($status, $errmsg) = ('ok', undef);
  my $r;
  print "{\n";
  
  eval {
    my $dbh = dbconn('spam');
    if(!ref($dbh)) { die "Cannot connect to database\n"; }
    for my $l (qw(this last)) {
      my $g = 0;
      my $l1 = substr($l, 0, 1);
      my $f;
      print qq<  "$l" : {\n>;
      for my $k (qw(day week month year)) {
        my $f = 0;
        my $k1 = substr($k, 0, 1);
        my $sth = $dbh->prepare("SELECT * FROM v_patching_$l1$k1 LIMIT 5");
        $r = $sth->execute();
        if(!$r) { die "Cannot query database (view v_patching_$l1$k1)\n"; }
        print ",\n" if $g;
        print qq<    "$k" : [\n>;
        while(my $ra = $sth->fetchrow_arrayref()) {
          print qq<,\n> if $f;
          printf(qq<      ["%s",%d]>, @$ra);
          $f = 1;
        }
        print "\n" if $f;
        print qq<    ]>;
        $g = 1;
      }
      print qq<\n  },\n>
    }
  };
  if($@) {
    chomp($@);
    $status = 'error';
    $errmsg = $@;
  }

  print qq<  "errmsg" : "$errmsg",\n> if $errmsg;
  print qq<  "status" : "$status"\n>;
  print "}\n";
}


#==========================================================================
#=== MAIN =================================================================
#==========================================================================

dbinit('spam', 'spam', 'swcgi', 'InvernessCorona', 'l5nets01');

my $q = new CGI;
my $qtype = $q->url_param('q');   # query type

#print qq{Content-type: text/plain; charset: utf-8\n\n};
print qq{Content-type: application/json; charset: utf-8\n\n};

given($qtype) {
  when('ppmap') { backend_ppmap($q); }
  when('patchact') { backend_patching_activity($q); }
}
