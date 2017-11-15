/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Switch List
 *==========================================================================*/


module.exports = switchList;

function switchList(shared, state) {


/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  modPortList = require('./portlist.js'),
  host;


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

  new modPortList(
    shared,
    {
      beRequest: arg,
      mount: '#content',
      template: 'switch',
      spinner: 'div#swlist'
    }
  );
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
    $('table#swlist tbody td.host span.lnk').on('click', function() {
      var new_host = $(this).text();
      state.host = new_host;
      shared.dispatch(null, state);
      portList.apply(this);
    });
  });
}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

//--- we can be called as /sw/ or /sw/HOST/, the latter case should display
//--- Port List, not Switches Lists */

if(state.hasOwnProperty('arg') && state.arg[0]) {
  host = state.arg[0];
}

//--- if called with no argument, just display the Switch List

if(!host) {

  // show spinner next to the menu entry
  $('div#swlist').addClass('spinner');

  // do an AJAX request to get the switch list data
  $.post(shared.backend, {r:'swlist'}, function(data) {

  // get user's active tab from local storage, set it to 'all' if none is
  // found

    var grp = localStorage.getItem('swlistgrp');
    data.grp = grp ? grp : 'all';

  // set filterhost context helper that sorts the switches into groups that
  // are switched with the top tabs

    data.filterhost = ctxHelperFilterhost;

  // render the page and remove spinner

    renderSwitchList(data);
    $('div#swlist').removeClass('spinner');
  });
}

//--- if called with an argument, display a Port List instead

else {
  new modPortList(
    shared,
    {
      beRequest: { r : "search", host: host, mode: "portlist" },
      mount: '#content',
      template: 'switch',
      error: 'switch-error',
      spinner: 'div#swlist'
    }
  );
}


/*--- end of module --------------------------------------------------------*/

}
