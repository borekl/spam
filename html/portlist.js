/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Port List
  
  Function that handles loading data for, displaying and servicing the
  port list view. The port list view must contain TABLE.list element.
  
  Configuration object passed to this:

  cfg.beRequest    ... request to be sent to the backend
  cfg.beResponse   ... response from backend
  cfg.mount        ... selector, DOM element or jQuery object
  cfg.template     ... dust.js template to be rendered
 *==========================================================================*/


module.exports = portList;

function portList(shared, cfg, success) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  modPortInfo = require('./portinfo.js'),
  jq_mount,
  jq_port_list,
  myCfg = Object.create(cfg);


/*--------------------------------------------------------------------------*
  Refresh handler
 *--------------------------------------------------------------------------*/

function refreshPortList()
{
  if('beRequest' in myCfg) {
    $.post(shared.backend, myCfg.beRequest, function(r) {
      myCfg.beResponse = r;
      processPortList();
    });
  } else if('beResponse' in myCfg) {
    processPortList();
  }
}


/*--------------------------------------------------------------------------*
  Render the port list and set up the handlers.
 *--------------------------------------------------------------------------*/

function processPortList()
{
  var r = myCfg.beResponse;
  
  if('status' in r && r.status == 'ok') {
    dust.render(myCfg.template, r, function(err, out) {
      jq_mount = $(myCfg.mount);
      jq_mount.html(out);
      jq_port_list = jq_mount.find('table.list')
      new modPortInfo(shared, jq_port_list);

      //--- refresh handler

      jq_port_list.on('refresh', refreshPortList);

      //--- invoke callback

      if($.isFunction(success)) {
        success(r);
      }
    });
  }
}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

if('beResponse' in myCfg && myCfg.beResponse) {
  processPortList();
} else {
  $.post(shared.backend, myCfg.beRequest, function(r) {
    myCfg.beResponse = r;
    processPortList();
  });
}

/*--- end of module --------------------------------------------------------*/

}
