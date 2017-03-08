/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Port List
  
  Function that handles loading data for, displaying and servicing the
  port list view. The port list view must contain TABLE.list element.
  
  Configuration object passed to this:

  cfg.beRequest    ... request to be sent to the backend
  cfg.beResponse   ... response from backend
  cfg.mount        ... selector, DOM element or jQuery object
  cfg.template     ... dust.js template to be rendered
  cfg.error        ... dust.js template in case of error
  cfg.spinner      ... element to add 'spinner' class to it
 *==========================================================================*/


module.exports = portList;

function portList(shared, cfg, success) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this,
  modPortInfo = require('./portinfo.js'),
  modEditable = require('./editable.js'),
  jq_mount,
  jq_port_list,
  myCfg = Object.create(cfg);


/*--------------------------------------------------------------------------*
  Dust.js context helper that returns true/false if a field (specified as
  "field" parameter) exists in search response fields list.
 *--------------------------------------------------------------------------*/

function ctxHelperExistsField(chunk, context, bodies, params)
{
  var
    search = context.get('search'),
    fields;

  if('fields' in search) {
    fields = search.fields;
    return fields.indexOf(params.field) === -1 ? false : true;
  }
  return false;
}


/*--------------------------------------------------------------------------*
  Refresh handler
 *--------------------------------------------------------------------------*/

this.refreshPortList = function()
{
  if('beRequest' in myCfg) {
    $(myCfg.spinner).addClass('spinner');
    $.post(shared.backend, myCfg.beRequest, function(r) {
      $(myCfg.spinner).removeClass('spinner');
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
  
  if('search' in r && r.search.status == 'ok' && r.search.lines > 0) {
    r.existsfield = ctxHelperExistsField;
    dust.render(myCfg.template, r, function(err, out) {
      jq_mount = $(myCfg.mount);
      jq_mount.html(out);
      jq_port_list = jq_mount.find('table.list')
      new modPortInfo(shared, jq_port_list, that);

      //--- bind hide/unhide handler to swinfo tables

      $('table.swinfo span.swsec').on('click', function(evt) {
        $(evt.currentTarget).parents('thead').next().toggle();
      });

      //--- bind editable to those module aux info fields
      
      $('span.modwire').on('click', function() {
        var m, n, jq_td;
        jq_td = $(this).parent();
        m = jq_td.data('m');
        n = jq_td.data('n');
        new modEditable(shared, {
          el: this,
          size: 8,
          spinclass: 'spineditable',
          errclass: 'moderrmsg',
          save: function(t) {
            var 
              deferred = $.Deferred(),
              post = {
                r: 'modwire', location: t, m: m, n: n,
                host: myCfg.beRequest.host
              };

            $.ajax({
              data: post,
              success: function(data) {
                if(data.status == 'ok') {
                  deferred.resolve();
                } else {
                  deferred.reject(data.errmsg);
                }
              },
              error: function() {
                deferred.reject('Server failure');
              }
            });
            
            return deferred;
          }
        });
      });
      
      //--- invoke callback

      if($.isFunction(success)) {
        success(r);
      }
    });
  }

  //--- error, the response indicates error or there are 0 lines in the result

  else {

    // 0 lines in the response, this is result of asking for non-existent
    // switch

    if('search' in r && r.search.status == 'ok' && r.search.lines == 0) {
      if('error' in myCfg && myCfg.error) {
        dust.render(myCfg.error , r, function(err, out) {
          jq_mount = $(myCfg.mount);
          jq_mount.html(out);
        });
      }
    }
  }
}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

if('beResponse' in myCfg && myCfg.beResponse) {
  processPortList();
} else {
  if(myCfg.spinner) { $(myCfg.spinner).addClass('spinner'); }
  $.post(shared.backend, myCfg.beRequest, function(r) {
    myCfg.beResponse = r;
    processPortList();
    if(myCfg.spinner) { $(myCfg.spinner).removeClass('spinner'); }
  });
}

/*--- end of module --------------------------------------------------------*/

}
