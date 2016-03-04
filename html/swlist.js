/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Switch List
 *==========================================================================*/
 

module.exports = switchList;

function switchList(shared) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  that = this;
  modPortInfo = require('./portinfo.js');


/*--------------------------------------------------------------------------*
  Dust.js context helper for filtering switch list.
 *--------------------------------------------------------------------------*/

function ctxHelperFilterhost(chunk, context, bodies, params)
{
  var grp = context.get('grp');
  
  if(
    grp == 'all'
    || (grp == 'stl' && context.get('stale') == 1)
    || context.get('group') == grp
  ) {
    chunk.render(bodies.block, context);
  }
                        
  return chunk;
}


/*--------------------------------------------------------------------------*
  Render port list.
 *--------------------------------------------------------------------------*/

function portList(el)
{
  var
    host = $(this).text(),
    arg = { r : "search", host: host, mode: "portlist" };

  $('div#swlist').addClass('spinner');
  $.get(shared.backend, arg, function(data) {
    dust.render('switch', data, function(err, out) {
      $('#content').html(out);
      $('div#swlist').removeClass('spinner');
      new modPortInfo(shared, 'table#portlist');
    });
  });
}


/*--------------------------------------------------------------------------*
  Render switch list.
 *--------------------------------------------------------------------------*/

function renderSwitchList(data)
{
  dust.render('swlist', data, function(err, out) {
    $('#content').html(out);
    $('div#swgroups span.selected').removeClass('selected');
    $('span[data-grp=' + data.grp + ']').toggleClass('selected');
    $('div#swgroups span').on('click', function() {
      data.grp = $(this).data('grp');
      // persistently save switch group unless the current group is 'stl'
      if(data.grp != 'stl') {
        localStorage.setItem('swlistgrp', data.grp);
      }
      renderSwitchList(data);
    });
    $('table#swlist tbody td.host span.lnk').on('click', portList);
  });
}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

$('div#swlist').addClass('spinner');
$.post(shared.backend, {r:'swlist'}, function(data) {
  var grp = localStorage.getItem('swlistgrp');
  data.grp = grp ? grp : 'all';
  data.filterhost = ctxHelperFilterhost;
  renderSwitchList(data);
  $('div#swlist').removeClass('spinner');
});


/*--- end of module --------------------------------------------------------*/

}
