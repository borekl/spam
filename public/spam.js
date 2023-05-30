(function() { //==============================================================


/*--------------------------------------------------------------------------*
  Initialization (FIXME: Dust really needs to be global?)
 *--------------------------------------------------------------------------*/

dust = require('dustjs-helpers');

var
  auxdata,
  modAddPatchesForm = require('./addpatches.js'),
  modSearchTool = require('./searchtool.js'),
  modSwitchList = require('./swlist.js'),
  shared = {
    backend: 'api/v0/',
    site_mode: {}  // cache of site mode values
  };
  selcodes = {
    sw: 'swlist',
    sr: 'srctool',
    ap: 'addpatch',
    ab: 'about'
  };



/*--------------------------------------------------------------------------*
  Function to get base URL.
 *--------------------------------------------------------------------------*/

shared.get_base = function(sel)
{
  var base = window.location.pathname.split('/').slice(0, 2).join('/') + '/';
  if(sel) {
    base += sel + '/';
  }
  return base;
}


/*--------------------------------------------------------------------------*
  isInteger polyfill.
 *--------------------------------------------------------------------------*/

Number.isInteger = Number.isInteger || function(value) {
  return typeof value === "number" &&
    isFinite(value) &&
    Math.floor(value) === value;
};


/*--------------------------------------------------------------------------*
  This function populates the "Logged as <login>" message in the sidebar.
 *--------------------------------------------------------------------------*/

function populate_login_info(data)
{
  if(data.status == 'ok' && data.userid) {
    $('span#login').text(data.userid);
    $('div#loginfo').css('display', 'block');
  }
}


/*--------------------------------------------------------------------------*
  Populate "sites" SELECT element from backend. If the SELECT element has
  'data-storage' attribute, the value is used as a key with saved value
  in Web Storage.
 *--------------------------------------------------------------------------*/

shared.populate_select_sites = function(idx, el, success)
{
  //--- function to perform the actual creation of OPTION elements

  var populate = function(aux) {
    var
      sites,
      jq_option;

    if(aux.sites.status == 'ok') {
      sites = aux.sites.result;
      for(var i = 0, len = sites.length; i < len; i++) {
        jq_option = $('<option></option>')
                    .attr('value', sites[i][0])
                    .text(sites[i][0]+' / '+sites[i][1]);
        $(el).append(jq_option);
      }
      auxdata = aux;
      if($.isFunction(success)) { success(idx, el); }
    }
  };

  //--- load data from backend or use cached values

  if(auxdata != undefined) {
    populate(auxdata);
  } else {
    $.get(shared.backend, {r: 'aux'}, populate, 'json');
  }
}


/*--------------------------------------------------------------------------*
  Set element's value from localStorage using data-storage custom attribute
  as the key.
 *--------------------------------------------------------------------------*/

shared.set_value_from_storage = function(el)
{
  var
    storage = $(el).data('storage');

  if(storage) {
    $(el).val(localStorage.getItem(storage));
    $(el).trigger('change');
  }
}


/*--------------------------------------------------------------------------*
  Central dispatching. This function will invoke various parts of the
  application based on URL or based on internal state as saved with
  History API pushState/replaceState functions. The function is invoked
  either as callback handler (for 'click' or 'popstate' events) or directly
  from other parts of the program. This mode of invocation is distinguished
  by the first argument 'evt'. If it is non-null, the function is invoked
  as event handler, otherwise it is called directly and the second argument
  'state_in' should be provided.
 *--------------------------------------------------------------------------*/

shared.dispatch = function(evt, state_in)
{
  var
    state = state_in,
    evt_type = evt ? evt.type : null,
    selsh;

  //--- if we are called as 'popstate' event handler, get the state from
  //--- the event object; note that jQuery doesn't know anything about
  //--- popstate, so we need to access the state property through the
  //--- originalEvent

  if(evt_type == 'popstate') {
    state = evt.originalEvent.state;
  }

  //--- if we are called as 'click' event handler, get the state.sel
  //--- from target element's id attribute

  if(evt_type == 'click') {
    state = {
      sel: $(this).attr('id')
    };
  }

  //--- allows for supplying state.sel as two-letter short code;
  //--- the mapping is defined in this file in selcodes

  if(!evt && state.sel.length == 2) {
    state.sel = selcodes[state.sel];
  }

  //--- debug

  if(state == null) {
    return;
  }

  //--- sidebar menu highlights

  $('div.menu#' + state.sel).trigger('spam.select');

  //--- central dispatch

  switch(state.sel) {

    case 'swlist':
      selsh = 'sw';
      if(state.hasOwnProperty('arg') && state.arg[0]) {
        selsh += '/' + state.arg[0];
      }
      if(state.host) { selsh += '/' + state.host; }
      if(!state.host) { new modSwitchList(shared, state); }
      break;

    case 'srctool' :
      selsh = 'sr';
      new modSearchTool(shared, state);
      break;

    case 'addpatch':
      selsh = 'ap';
      new modAddPatchesForm(shared, state);
      break;

    case 'about' :
      selsh = 'ab';
      dust.render('about', {}, function(err, out) {
        $('#content').html(out);
      });
      break;

    default:
      alert('Invalid dispatch selector: ' + state.sel);

  }

  if(selsh && evt_type != 'popstate') {
    history.pushState(state, null, shared.get_base(selsh));
  }
}



/*==========================================================================*
  === MAIN =================================================================
 *==========================================================================*/

$(document).ready(function()
{
  var url, state = {};

  //--- jQuery AJAX setup

  $.ajaxSetup({
    url: shared.backend
  });

  //--- process URL

  // we implement semantic URLs to allow deep-linking to certain parts
  // of the application; the semantic URL is enforced by following
  // mod_rewrite rule:
  //
  // RewriteRule "^/spam/[a-z]{2}/[^/]*$" "/spam/" [PT,L]

  state.arg = document.location.pathname
              .split('/') // decompose into path elements
              .splice(2)  // drop the first two elements
              .filter(    // remove empty elements
                function(s) {
                  return s != "";
                }
              );
  state.sel = state.arg.shift();

  //--- fill in "logged as" display

  $.get(shared.backend, populate_login_info);

  //--- handle sidebar menu highlights

  $('div.menu').on('spam.select', function() {
    $('div.selected').removeClass('selected');
    $(this).addClass('selected');
  });

  //--- handle menu clicks

  $('div.menu').on('click', shared.dispatch);

  //--- popstate handler

  $(window).on('popstate', shared.dispatch);

  //--- go to URL-specified page

  if(!state.sel) { state.sel = 'swlist'; }
  shared.dispatch(null, state);

});


})(); //======================================================================
