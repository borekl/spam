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
 *==========================================================================*/
 

module.exports = portInfo;

function portInfo(shared, mount) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  jq_table,       // TABLE we are servicing
  jq_tbody,       // TABLE's TBODY we are servicing
  host,           // switch hostname the current table shows
  pn_col,         // what column contains portname
  hn_col,         // what column contains hostname
  ncols,          // how many colums do regular rows in this table have
  spin = '<div class="spinner"><img src="assets/spin.svg"></div>';


/*--------------------------------------------------------------------------*
  Display the port info; this points to the row that invoked this.
 *--------------------------------------------------------------------------*/

function portInfoShow()
{
  var 
    portname = $(this).children().eq(pn_col).text(),
    hostname = host,
    jq_row_orig,  // original table row
    jq_row_pi,    // new table row with the Port Info display
    jq_td_pi,     // new row's inner TD
    srcdata = {}  // data for backend query

  //--- get hostname of the switch
  
  if(!hostname) {
    hostname = $(this).children().eq(hn_col).text();
  }

  // close any previous instance on the same table

  jq_tbody.find('div.pi-container').each(function() { 
    $(this).trigger('dismiss'); 
  });

  // create new row and detach the old one

  jq_row_pi = 
    $('<tr class="pi"><td colspan="'+ncols+'">'+spin+'</td></tr>')
    .insertAfter(this);
  jq_td_pi = jq_row_pi.children('td');
  jq_row_orig = $(this).detach();
  
  // close the Port Info with a button

  function bind_close() {
    jq_td_pi.on('dismiss', function(evt) {
      jq_row_orig.insertAfter(jq_row_pi);
      jq_row_pi.remove();
      evt.stopPropagation();
    });
    jq_td_pi.find('button[name="pi-close"]').on('click', function(evt) {
      $(this).trigger('dismiss');
      evt.stopPropagation();
    });
  }

  // retrieve data from backend & render

  srcdata = {r: 'portinfo', host:hostname, portname: portname }
  $.post(shared.backend, srcdata, function(result) {
    dust.render('portinfo', result, function(err, out) {
      jq_td_pi.html(out);
      bind_close();
    });
  });

}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

//--- get TABLE and TBODY refs ready

jq_table = $(mount);
if(jq_table.length != 1) { return; }
jq_tbody = jq_table.find('tbody');

//--- resolve input data

host = jq_table.data('host');
hn_col = Number(host);
if(Number.isInteger(hn_col)) { host = undefined; }
pn_col = Number(jq_table.data('portname'));
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
