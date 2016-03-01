/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Port Info
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
  pname_col,      // what column contains portname
  ncols;          // how many colums do regular rows in this table have


/*--------------------------------------------------------------------------*
  Display the port info; this points to the row that invoked this.
 *--------------------------------------------------------------------------*/

function portInfoShow()
{
  var 
    portname = $(this).children().eq(0).text(),
    jq_row_orig,  // original table row
    jq_row_pi,    // new table row with the Port Info display
    jq_td_pi,     // new row's inner TD
    srcdata = {}  // data for backend query

  // close any previous instance on the same table

  jq_tbody.find('div.pi-container').each(function() { 
    $(this).trigger('click'); 
  });

  // create new row and detach the old one

  jq_row_pi = 
    $('<tr class="pi"><td colspan="'+ncols+'"></td></tr>')
    .insertAfter(this);
  jq_td_pi = jq_row_pi.children('td');
  jq_row_orig = $(this).detach();
  
  // retrieve data from backend & render

  srcdata = {r: 'portinfo', host:host, portname: portname }
  $.post(shared.backend, srcdata, function(result) {
    dust.render('portinfo', result, function(err, out) {
      jq_td_pi.html(out);
    });
  });

  // close the Port Info view upon click anywhere within it

  jq_td_pi.on('click', function(evt) {
    jq_row_orig.insertAfter(jq_row_pi);
    jq_row_pi.remove();
  });
}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

jq_table = $(mount);
jq_tbody = jq_table.find('tbody');

host = jq_table.data('host');
pi_col = Number(jq_table.data('portinfo'));
ncols = jq_tbody.find('tr.portinfo:first').children().length;

jq_table.on('click', function(evt) {
  var jq_target_tr = $(evt.target).parents('tr');
  if(jq_target_tr.hasClass('portinfo')) {
    portInfoShow.call(jq_target_tr.get(0));
  }
});


/*--- end of module --------------------------------------------------------*/

}
