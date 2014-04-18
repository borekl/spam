#!/usr/bin/perl -I/opt/spam

#==========================================================================
# SWITCH PORTS ACTIVITY MONITOR -- PPMAP BACKEND
# """"""""""""""""""""""""""""""""""""""""""""""
# 2009 Borek Lupomesky <borek.lupomesky@vodafone.com>
#
# This script constitutes back-end (server) portion of Patch Panel Map
# Tool's visualization feature. It accepts "id" parameter which consists
# of concatenated site and room identifiers, both three letters, and
# returns CSV-like text containing complete ppmap data for given site.
# Client-side JavaScript (ppmap.js) then displays the data in graphic form
# using HTML Canvas.
#==========================================================================

use CGI;
use SPAMv2;
use strict;
use integer;

my $query = <<EOHD;
SELECT p.col, p.row, p.pos, p.name, p.type, s.host, s.portname, 
  extract(epoch from s.lastchk) - extract(epoch from s.lastchg), 
  s.adminstatus, s.status, s.errdis
FROM ppmap p
LEFT JOIN status s ON (s.host = lower(split_part(p.name,' ',1)) AND substring(portname from '\\\\d+/\\\\d+\$') = split_part(p.name,' ',2))
LEFT JOIN ( SELECT host, switch_has_dupports(host) AS dup FROM ( SELECT DISTINCT host FROM status ) AS ds ) AS d ON s.host = d.host
WHERE NOT (d.dup IS TRUE AND s.portname ~ '^Gi')
EOHD

dbinit('spam', 'spam', 'swcgi', 'InvernessCorona', undef);

my $q = new CGI;
my $id = $q->url_param('id');
$id =~ /^(...)(...)$/;  
my ($site, $room) = (lc($1), uc($2));

if($site && $room) {
  my $i = 0;
  my @qry;
  my ($col_min, $col_max, $row_min, $row_max);
  
  print qq{Content-type: text/plain; charset: utf-8\n\n};

  my $dbh = dbconn('spam');
  my $qry = $query . qq{ AND p.site = '$site' AND p.room = '$room' ORDER BY col, row, pos};
  my $sth = $dbh->prepare($qry);
  if($sth->execute()) {
    while(my @a = $sth->fetchrow_array()) {
      $qry[$i++] = \@a;
      $col_min = $a[0] if !defined($col_min) || $col_min > $a[0];
      $col_max = $a[0] if !defined($col_max) || $col_max < $a[0];
      $row_min = $a[1] if !defined($row_min) || $row_min > $a[1];
      $row_max = $a[1] if !defined($row_max) || $row_max < $a[1];
    }
    
    #print $qry, "\n";
    #print '---', "\n";

    printf("ok\n");
    printf("%d|%d|%d|%d|%d\n", $i, $col_min, $col_max, $row_min, $row_max);    
    
    for(my $j = 0; $j < $i; $j++) {
      printf("%d|%d|%d|%s|%s|%s|%s|%d|%d|%d|%d\n",@{$qry[$j]});
    }
  } else {
    printf("error\n");
    printf("Cannot query database (%s)\n", $sth->errstr);
  }
}
