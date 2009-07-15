# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#TODO: delete entries not being refreshed if no noderange
package xCAT_plugin::conserver;
use strict;
use xCAT::Table;
use xCAT::Utils;
use Getopt::Long;
use Sys::Hostname;

use strict;
use Data::Dumper;
my @cservers = qw(mrv cyclades);
my %termservers; #list of noted termservers

my $usage_string=
"  makeconservercf [-d|--delete] noderange
  makeconservercf [-l|--local]
  makeconservercf 
  makeconservercf -h|--help
  makeconservercf -v|--version
    -l|--local   The conserver gets set up only on the local host.
                 The default goes down to all the conservers on
                 the server nodes and set them up
    -d|--delete  Conserver has the relevant entries for the given noderange removed immediately from configuration
    -h|--help    Display this usage statement.
    -v|--version Display the version number.";

my $version_string=xCAT::Utils->Version(); 

sub handled_commands {
  return {
    makeconservercf => "conserver"
  }
}

sub preprocess_request {
  my $request = shift;
  #if ($request->{_xcatdest}) { return [$request]; }    #exit if preprocessed
  if ($request->{_xcatpreprocessed}->[0] == 1) { return [$request]; }
  my $callback=shift;
  my @requests;
  my $noderange = $request->{node}; #Should be arrayref 

  #display usage statement if -h
  my $extrargs = $request->{arg};
  my @exargs=($request->{arg});
  if (ref($extrargs)) {
    @exargs=@$extrargs;
  }
  @ARGV=@exargs;

  my $isSN=xCAT::Utils->isServiceNode();
  my @hostinfo=xCAT::Utils->determinehostname();
  my %iphash=();
  foreach(@hostinfo) { $iphash{$_}=1;}

  $Getopt::Long::ignorecase=0;
  #$Getopt::Long::pass_through=1;
  if(!GetOptions(
      'l|local'     => \$::LOCAL,
      'h|help'     => \$::HELP,
      'v|version'  => \$::VERSION)) {
    $request = {};
    return;
  }
  if ($::HELP) {
    $callback->({data=>$usage_string});
    $request = {};
    return;
  }
  if ($::VERSION) {
    $callback->({data=>$version_string});
    $request = {};
    return;
  }
  if ($::LOCAL) {
    if ($noderange && @$noderange>0) {
      $callback->({data=>"Invalid option -l or --local when there are nodes specified."});
      $request = {};
      return;
    }
  }
  
  
  # get site master
  my $master=xCAT::Utils->get_site_Master();
  if (!$master) { $master=hostname(); }

  # get conserver for each node
  my %cons_hash=();
  my $hmtab = xCAT::Table->new('nodehm');
  my @items;
  my $allnodes=1;
  if ($noderange && @$noderange>0) {
    $allnodes=0;
    my $hmcache=$hmtab->getNodesAttribs($noderange,['node', 'serialport','cons', 'conserver']);
    foreach my $node (@$noderange) {
      my $ent=$hmcache->{$node}->[0]; #$hmtab->getNodeAttribs($node,['node', 'serialport','cons', 'conserver']);
      push @items,$ent;
    }
  } else {
    $allnodes=1;
    @items = $hmtab->getAllNodeAttribs(['node', 'serialport','cons', 'conserver']);
  }

  my @nodes=();
  foreach (@items) {
    if (((!defined($_->{cons})) || ($_->{cons} eq "")) and !defined($_->{serialport})) { next;} #skip if 'cons' is not defined for this node, unless serialport suggests otherwise
    if (defined($_->{conserver})) { push @{$cons_hash{$_->{conserver}}{nodes}}, $_->{node};}
    else { push @{$cons_hash{$master}{nodes}}, $_->{node};}
    push @nodes,$_->{node};
  }

  #send all nodes to the MN
  if (!$isSN) { #
    my $reqcopy = {%$request};
    $reqcopy->{'_xcatdest'} = $master;
    $reqcopy->{_xcatpreprocessed}->[0] = 1;
    $reqcopy->{'_allnodes'} = $allnodes; # the original command comes with nodes or not
    if ($allnodes==1) { @nodes=(); }
    $reqcopy->{node} = \@nodes;
    push @requests, $reqcopy;
    if ($::LOCAL) { return \@requests; }
  }

  # send to SN
  foreach my $cons (keys %cons_hash) {
    #print "cons=$cons\n";
    my $doit=0;
    if ($isSN) {
      if (exists($iphash{$cons})) { $doit=1; }
    } else {
      if (!exists($iphash{$cons})) { $doit=1; }
    }

    if ($doit) {
      my $reqcopy = {%$request};
      $reqcopy->{'_xcatdest'} = $cons;
      $reqcopy->{_xcatpreprocessed}->[0] = 1;
      $reqcopy->{'_allnodes'} = [$allnodes]; # the original command comes with nodes or not
      $reqcopy->{node} = $cons_hash{$cons}{nodes};
      my $no=$reqcopy->{node};
      #print "node=@$no\n";
      push @requests, $reqcopy;
    }
  }
  return \@requests;
}

sub process_request {
  my $req = shift;
  my $cb = shift;
  if ($req->{command}->[0] eq "makeconservercf") {
    makeconservercf($req,$cb);
  }
}

sub docfheaders {
# Put in standard headers common to all conserver.cf files
  my $content = shift;
  my @newheaders=();
  my $numlines = @$content;
  my $idx = 0;
  my $skip = 0;
  my @meat = grep(!/^#/,@$content);
  unless (grep(/^config \* {/,@meat)) {
    push @newheaders,"config * {\n";
    push @newheaders,"  sslrequired yes;\n";
    push @newheaders,"  sslauthority /etc/xcat/cert/ca.pem;\n";
    push @newheaders,"  sslcredentials /etc/xcat/cert/server-cred.pem;\n";
    push @newheaders,"}\n";
  }
  unless (grep(/^default cyclades/,@meat)) {
    push @newheaders,"default cyclades { type host; portbase 7000; portinc 1; }\n"
  }
  unless (grep(/^default mrv/,@meat)) {
    push @newheaders,"default mrv { type host; portbase 2000; portinc 100; }\n"
  }
  #Go through and delete that which would match access and default
  while($idx < @$content){
    if (($content->[$idx] =~ /^access \*/)
      ||($content->[$idx] =~ /^default \*/)) {
      $skip = 1;
    }
    if ($skip == 1){
      splice(@$content, $idx, 1);
    } else {
      $idx++;
    }
    if($skip and $content->[$idx] =~ /\}/){
      splice(@$content, $idx, 1);
      $skip = 0;
    }
  }
  #push @$content,"#xCAT BEGIN ACCESS\n";
  push @newheaders,"access * {\n";
  push @newheaders,"  trusted 127.0.0.1;\n";
  if (xCAT::Utils->isServiceNode()) {
    my $master=xCAT::Utils->get_site_Master();
    push @newheaders, "  trusted $master;\n";
  }
  push @newheaders,"}\n";
  #push @$content,"#xCAT END ACCESS\n";

  push @newheaders,"default * {\n";
  push @newheaders,"  logfile /var/log/consoles/&;\n";
  push @newheaders,"  timestamp 1hab;\n";
  push @newheaders,"  rw *;\n";
  push @newheaders,"  master localhost;\n";

  #-- if option "conserverondemand" in site table is set to yes
  #-- then start all consoles on demand
  #-- this helps eliminate many ssh connections to blade AMM
  #-- which seems to kill AMMs occasionally
  my $sitetab  = xCAT::Table->new('site');
  my $vcon = $sitetab->getAttribs({key => "consoleondemand"}, 'value');
  if ($vcon and $vcon->{"value"} and $vcon->{"value"} eq "yes" ) {
    push @newheaders,"  options ondemand;\n";
  }

  push @newheaders,"}\n";
  unshift @$content,@newheaders;


}
sub makeconservercf {
  my $req = shift;
  %termservers = (); #clear hash of existing entries
  my $cb = shift;
  my $extrargs = $req->{arg};
  my @exargs=($req->{arg});
  if (ref($extrargs)) {
    @exargs=@$extrargs;
  }
  @ARGV=@exargs;
  $Getopt::Long::ignorecase=0;
  #$Getopt::Long::pass_through=1;
  my $delmode;
  GetOptions('d|delete'  => \$delmode);
  my $nodes = $req->{node};
  my $svboot=0;
  if (exists($req->{svboot})) { $svboot=1;}
  my $cfile;
  my @filecontent;
  open $cfile,'/etc/conserver.cf';
  while (<$cfile>) {
    push @filecontent,$_;
  }
  close $cfile;
  docfheaders(\@filecontent);

  my $isSN=xCAT::Utils->isServiceNode();
  my @hostinfo=xCAT::Utils->determinehostname();
  my %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}

  #print "process_request nodes=@$nodes\n";

  my $hmtab = xCAT::Table->new('nodehm');
  my @cfgents1;# = $hmtab->getAllNodeAttribs(['cons','serialport','mgt','conserver','termserver','termport']);
  if (($nodes and @$nodes > 0) or $req->{noderange}->[0]) {
      @cfgents1 = $hmtab->getNodesAttribs($nodes,['cons','serialport','mgt','conserver','termserver','termport']);
#to make the result consistent to getAllNodeAttribs
      my @tmpcfgents1;
      foreach my $ent (@cfgents1)
      {
          foreach my $nodeent ( keys %$ent)
          {
              push @tmpcfgents1, $ent->{$nodeent}->[0] ;
          }
      }
      @cfgents1 = @tmpcfgents1

  } else {
    @cfgents1 = $hmtab->getAllNodeAttribs(['cons','serialport','mgt','conserver','termserver','termport']);
  }


#cfgents should now have all the nodes, so we can fill in our hashes one at a time.

  # skip the one that does not have 'cons' defined, unless a serialport setting suggests otherwise
  my @cfgents=();
  foreach (@cfgents1) {
    if ($_->{cons} or defined($_->{'serialport'})) { push @cfgents, $_; }
  }

  # get the teminal servers and terminal port when cons is mrv or cyclades
  foreach (@cfgents) {
     unless ($_->{cons}) {$_->{cons} = $_->{mgt};} #populate with fallback
    #my $cmeth=$_->{cons};
    #if (grep(/^$cmeth$/,@cservers)) { #terminal server, more attribs needed
    #  my $node = $_->{node};
    #  my $tent = $hmtab->getNodeAttribs($node,["termserver","termport"]);
    #  $_->{termserver} = $tent->{termserver};
    #  $termservers{$tent->{termserver}} = 1;
    #  $_->{termport}= $tent->{termport};
    #}
  }

  # nodes defined, it is either on the service node or mkconserver is call with noderange on mn
  if (($nodes and @$nodes > 0) or $req->{noderange}->[0]) {
    # strip all xCAT configured stuff from config if the original command was for all nodes
    if (($req->{_allnodes}) && ($req->{_allnodes}->[0]==1)) {zapcfg(\@filecontent);}
    foreach (@$nodes) {
      my $node = $_;
      foreach (@cfgents) {
        if ($_->{node} eq $node) {
          if ($_->{termserver} and not $termservers{$_->{termserver}}) {
            dotsent($_,\@filecontent);
            $termservers{$_->{termserver}}=1; #prevent needless cycles being burned
          }
          donodeent($_,\@filecontent,$delmode);
        }
      }
    }
  } else { #no nodes specified, do em all up
    zapcfg(\@filecontent); # strip all xCAT configured stuff from config

    # filter out node types without console support
    my $typetab = xCAT::Table->new('nodetype');
    my %type;

    if ( defined($typetab)) {
      my @ents = $typetab->getAllNodeAttribs([qw(node nodetype)]);
      foreach (@ents) {
        $type{$_->{node}}=$_->{nodetype};
      }
    }
    foreach (@cfgents) {
      my $keepdoing=0;
      if ($isSN && $_->{conserver} && exists($iphash{$_->{conserver}}))  {
        $keepdoing=1;  #only hanlde the nodes that use this SN as the conserver
      }
      if (!$isSN) { $keepdoing=1;} #handle all for MN
      if ($keepdoing) {
        if ($_->{termserver} and not $termservers{$_->{termserver}}) {
          dotsent($_,\@filecontent);
          $termservers{$_->{termserver}}=1; #prevent needless cycles being burned
        }
        if ( $type{$_->{node}} !~ /fsp|bpa|hmc|ivm/ ) {
          donodeent($_,\@filecontent);
        }
      }
    }
  }
  open $cfile,'>','/etc/conserver.cf';
  foreach (@filecontent) {
    print $cfile $_;
  }
  close $cfile;


  if (!$svboot) {
    #restart conserver daemon
    my $cmd;
    if(xCAT::Utils->isAIX()){
       if (-f "/var/run/conserver.pid") {
        $cmd = "stopsrc -s conserver";
        xCAT::Utils->runcmd($cmd, 0);
        $cmd = "startsrc -s conserver";
        xCAT::Utils->runcmd($cmd, 0);
      } else {
        $cmd = "startsrc -s conserver";
        xCAT::Utils->runcmd($cmd, 0);
      }
    } else {
      if (-f "/var/run/conserver.pid") {
        $cmd = "/etc/init.d/conserver stop";
        xCAT::Utils->runcmd($cmd, 0);
        $cmd = "/etc/init.d/conserver start";
        xCAT::Utils->runcmd($cmd, 0);
      } else {
        $cmd = "/etc/init.d/conserver start";
        xCAT::Utils->runcmd($cmd, 0);
      }
    }
  }
}

sub dotsent {
  my $cfgent = shift;
  my $tserv = $cfgent->{termserver};
  my $content = shift;
  my $idx = 0;
  my $toidx = -1;
  my $skip = 0;
  my $skipnext = 0;

  while ($idx < $#$content) { # Go through and delete that which would match my entry
    if ($content->[$idx] =~ /^#xCAT BEGIN $tserv TS/) {
      $toidx=$idx; #TODO put it back right where I found it
      $skip = 1;
      $skipnext=1;
    } elsif ($content->[$idx] =~ /^#xCAT END $tserv TS/) {
      $skipnext = 0;
    }
    if ($skip) {
      splice (@$content,$idx,1);
    } else {
      $idx++;
    }
    $skip = $skipnext;
  }
  push @$content,"#xCAT BEGIN $tserv TS\n";
  push @$content,"default $tserv {\n";
  push @$content,"  include ".$cfgent->{cons}.";\n";
  push @$content,"  host $tserv;\n";
  push @$content,"}\n";
  push @$content,"#xCAT END $tserv TS\n";

}

sub donodeent {
  my $cfgent = shift;
  my $node = $cfgent->{node};
  my $content = shift;
  my $delmode = shift;
  my $idx=0;
  my $toidx=-1;
  my $skip = 0;
  my $skipnext = 0;

  my $isSN=xCAT::Utils->isServiceNode();

  while ($idx <= $#$content) { # Go through and delete that which would match my entry
    if ($content->[$idx] =~ /^#xCAT BEGIN $node CONS/) {
      $toidx=$idx; #TODO put it back right where I found it
      $skip = 1;
      $skipnext=1;
    } elsif ($content->[$idx] =~ /^#xCAT END $node CONS/) {
      $skipnext = 0;
    }
    if ($skip) {
      splice (@$content,$idx,1);
    } else {
      $idx++;
    }
    $skip = $skipnext;
  }
  if ($delmode) {
      return;
  }
  push @$content,"#xCAT BEGIN $node CONS\n";
  push @$content,"console $node {\n";
  #if ($cfgent->{cons}
  my $cmeth=$cfgent->{cons};
  #print $cmeth."\n";
  if (grep(/^$cmeth$/,@cservers)) {
    push @$content," include ".$cfgent->{termserver}.";\n";
    push @$content," port ".$cfgent->{termport}.";\n";
    if ((!$isSN) && ($cfgent->{conserver}) && xCAT::Utils->thishostisnot($cfgent->{conserver})) { # let the master handle it
      push @$content,"  master ".$cfgent->{conserver}.";\n";
    }
  } else { #a script method...
    push @$content,"  type exec;\n";
    if ((!$isSN) && ($cfgent->{conserver}) && xCAT::Utils->thishostisnot($cfgent->{conserver})) { # let the master handle it
      push @$content,"  master ".$cfgent->{conserver}.";\n";
    } else { # handle it here
      my $locerror = $isSN ? "PERL_BADLANG=0 " : '';    # on service nodes, often LC_ALL is not set and perl complains
      push @$content,"  exec $locerror".$::XCATROOT."/share/xcat/cons/".$cmeth." ".$node.";\n"
    }
  }
  push @$content,"}\n";
  push @$content,"#xCAT END $node CONS\n";
}

sub zapcfg {
  my $content = shift;
  my $idx=0;
  my $toidx=-1;
  my $skip = 0;
  my $skipnext = 0;
  while ($idx <= $#$content) { # Go through and delete that which would match my entry
    if ($content->[$idx] =~ /^#xCAT BEGIN/) {
      $toidx=$idx; #TODO put it back right where I found it
      $skip = 1;
      $skipnext=1;
    } elsif ($content->[$idx] =~ /^#xCAT END/) {
      $skipnext = 0;
    }
    if ($skip) {
      splice (@$content,$idx,1);
    } else {
      $idx++;
    }
    $skip = $skipnext;
  }
}


1;








