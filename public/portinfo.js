/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Port Info

  The UI to display extended port information. The constructor is called
  with a selector that should resolve into a single table, that holds
  Port List, Search Tool or Add Patches result tables. Every TR that
  can display extended port info via this module must have class "portinfo".

  The table must have two custom attributes:

  "data-host"
  contains either hostname of the switch itself; or number of column
  where hostname should be taken from

  "data-portname"
  contains number of column containing portname

  FIXME: Removing/adding patch triggers refresh in the portlist, but
  currently this refresh happens only after the Port Info is closed; ie.
  merely opening another Port Info on another port won't refresh the table.
 *==========================================================================*/


module.exports = portInfo;

function portInfo(shared, mount, portlist) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  modAddPatchesForm = require('./addpatches.js'),
  jq_table,        // TABLE we are servicing
  jq_tbody,        // TABLE's TBODY we are servicing
  jq_row_orig,     // this holds the original DOM table row replaced with pi
  jq_row_pi,       // new table row with the Port Info display
  jq_td_pi,        // new row's inner TD
  srcdata = {},    // data for backend query
  tabinfo = {},    // table data (supplied in custom attributes)
  ncols,           // how many columns do regular rows in this table have
  refresh = false, // refresh the portlist (after deleting a patch)
  spin = '<div class="pi-spinner"><img src="assets/spin-black.svgz"></div>';
                   // spinner HTML to be displayed before the data load


/*--------------------------------------------------------------------------*
  Function to implement "Are you sure (y/n)?" message. Intended to be
  wrapped around an event handler:

    .on('click', are_you_sure('message', original_callback));

  This should probably be spun off to its separate module or into main.
 *--------------------------------------------------------------------------*/

function are_you_sure(mesg, callback)
{
  var
    jq_parent, jq_saved,
    msg = { msg: mesg };

  jq_parent = $(this).parent();
  jq_saved = jq_parent.children().detach();
  dust.render('areyousure', msg, function(err, out) {
    jq_parent.html(out);

    jq_parent.find('button').on('click', function(evt) {
      var name = $(evt.target).attr('name');
      if(name == 'yes') {
        callback();
      }
      jq_parent.empty();
      jq_parent.append(jq_saved);
    });

  });
}


/*--------------------------------------------------------------------------*
  Dismiss the Port Info display.
 *--------------------------------------------------------------------------*/

function portInfoDismiss(evt)
{
  if(jq_row_orig) {
    jq_row_orig.insertAfter(jq_row_pi);
    jq_row_pi.remove();
    if(evt) { evt.stopPropagation(); }
    jq_row_orig = undefined;
  }
}


/*--------------------------------------------------------------------------*
  Display the port info; this points to the row that invoked this. "this" is
  the clicked TR element.
 *--------------------------------------------------------------------------*/

function portInfoShow()
{
  var
    portname = $(this).children().eq(tabinfo.portname).text(),
    hostname = tabinfo.host;

  //--- get hostname of the switch

  if(Number.isInteger(hostname)) {
    hostname = $(this).children().eq(tabinfo.host).text();
  }

  // close any previous instance on the same table

  portInfoDismiss();

  // create new row and detach the old one

  jq_row_pi =
    $('<tr class="pi"><td colspan="'+ncols+'">'+spin+'</td></tr>')
    .insertAfter(this);
  jq_td_pi = jq_row_pi.children('td');
  jq_row_orig = $(this).detach();

  // close the Port Info with a button

  function bind_close() {
    jq_td_pi.find('button[name="pi-close"]').on('click', function(evt) {
      portInfoDismiss();
      if(refresh) { portlist.refreshPortList(); }
      evt.stopPropagation();
    });
  }

  // expose and bind the "Remove Patch" button if 'cp' exists
  // FIXME. THIS IS UGLY, HOW TO DO THIS IN A MORE SANE WAY?

  function bind_remove(r) {
    if('cp' in r.search.result) {
      var jq_button = jq_td_pi.find('button[name="pi-delete"]');
      jq_button.removeClass('nodisp').on('click', function() {
        are_you_sure.call(
          jq_button.get(),
          'delete the patch from database',
          function() {
            jq_out = $('div.pi-outlet span');
            jq_out.css('opacity', '0.5');
            jq_button.removeClass('svg-dustbin').addClass('svg-spinner');
            $.post(shared.backend, {
              r: 'delpatch',
              host: r.search.result.host,
              portname: r.search.result.portname
            }, function(delres) {
              jq_button.removeClass('svg-spinner').addClass('svg-dustbin');
              if(delres.status == 'ok') {
                jq_button.addClass('nodisp');
                jq_out.empty();
                refresh = true;
                delete r.search.result.cp;
                bind_patch(r);
              } else {
                jq_out.css('opacity', '1');
                $('div.pi-actions').toggleClass('nodisp');
                $('span.pi-errmsg')
                .text(
                  'Patch was not removed because of an error'
                );
                $('button[name="pi-fail"]').on('click', function() {
                  $('div.pi-actions').toggleClass('nodisp');
                  $(this).off('click');
                });
              }
            });
          }
        );
      });
    }
  }

  // expose and bind the  "Patch This" button if 'cp' does not exist

  function bind_patch(r) {
    if(!('cp' in r.search.result)) {
      var jq_button = jq_td_pi.find('button[name="pi-patch"]');
      jq_button.removeClass('nodisp').off('click').on('click', function() {
        var values = {}, v;
        ['host', 'portname', 'cp', 'outlet'].forEach(function(k, i) {
          if(k in tabinfo) {
            v = jq_row_orig.children().eq(tabinfo[k]).text();
            if(v) { values[k] = v; }
          }
        });
        if(!('host' in values)) {
          values.host = jq_table.data('host');
        }
        values.site = values.host.substr(0, 3);
        shared.dispatch(null, { sel: 'addpatch', values: values });
      });
    }
  }

  // retrieve data from backend & render

  srcdata = {r: 'portinfo', host:hostname, portname: portname }
  $.post(shared.backend, srcdata, function(result) {
    dust.render('portinfo', result, function(err, out) {
      jq_td_pi.html(out);
      bind_close();
      bind_remove(result);
      bind_patch(result);
    });
  });

}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

//--- get TABLE and TBODY refs ready, ensure the 'mount' resolves to exactly
//--- one element

jq_table = $(mount);
if(jq_table.length != 1) { return; }
jq_tbody = jq_table.find('tbody');

//--- resolve input data

['host', 'portname', 'cp', 'outlet'].forEach(function(k, i) {
  var n = Number(jq_table.data(k));
  if(Number.isInteger(n)) {
    tabinfo[k] = n;
  }
});
if(!('host' in tabinfo)) {
  tabinfo.host = jq_table.data('host');
}
ncols = jq_tbody.find('tr.portinfo:first').children().length;

//--- hook into click anywhere in the body

jq_table.on('click', function(evt) {
  var jq_target_tr = $(evt.target).parents('tr');
  if(jq_target_tr.hasClass('portinfo')) {
    portInfoShow.call(jq_target_tr.get(0));
  }
});


/*--- end of module --------------------------------------------------------*/

}
