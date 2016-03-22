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
    backend: 'spam-backend.cgi',
    site_mode: {}  // cache of site mode values
  };



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


/*==========================================================================*
  === MAIN =================================================================
 *==========================================================================*/

$(document).ready(function() 
{
  var url, url_sel, url_arg;
  
  //--- process URL

  // we implement semantic URLs to allow deep-linking to certain parts
  // of the application; the semantic URL is enforced by following
  // mod_rewrite rule:
  //
  // RewriteRule "^/spam-dev/[a-z]{2}/[^/]*$" "/spam-dev/" [PT,L]

  url = document.location.pathname.split('/');
  url_sel = url[2];
  url_arg = url[3];
    
  //--- fill in "logged as" display
  
  $.get(shared.backend, populate_login_info);

  //--- handle sidebar menu highlights
  
  $('div.menu').on('click', function() {
    $('div.selected').removeClass('selected');
    $(this).addClass('selected');
  });

  //--- switch list

  $('div#swlist').on('click', function() {
    new modSwitchList(shared);
  });
  
  //--- search tool
  
  $('div#srctool').on('click', function() {
    new modSearchTool(shared);
  });
  
  //--- add patches
  
  $('div#addpatch').on('click', function() {
    new modAddPatchesForm(shared);
  });
  
  //--- about
  
  $('div#about').on('click', function() {
    dust.render('about', {}, function(err, out) {
      $('#content').html(out);
    });
  });
  
  //--- go to specified page
  
  if(url_sel == 'sw' && !url_arg) {
    $('div#swlist').trigger('click');
  } else if(url_sel == 'sr') {
    $('div#srctool').trigger('click');
  } else if(url_sel == 'ap') {
    $('div#addpatch').trigger('click');
  } else if(url_sel == 'ab') {
    $('div#about').trigger('click');
  } else {
    $('div#swlist').trigger('click');
  }
  
});


})(); //======================================================================
