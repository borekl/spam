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
    pss: populate_select_sites
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

function populate_select_sites(idx, el)
{
  //--- function to perform the actual creation of OPTION elements
  
  var populate = function(aux) {
    var 
      sites,
      jq_option,
      storage = $(el).data('storage');
    
    if(aux.sites.status == 'ok') {
      sites = aux.sites.result;
      for(var i = 0, len = sites.length; i < len; i++) {
        jq_option = $('<option></option>')
                    .attr('value', sites[i][0])
                    .text(sites[i][0]+' / '+sites[i][1]);
        $(el).append(jq_option);
      }
      if(storage) {
        $(el).val(localStorage.getItem(storage));
        $(el).trigger('change');
      }
      auxdata = aux;
    }
  };

  //--- load data from backend or use cached values
  
  if(auxdata != undefined) {
    populate(auxdata);
  } else {  
    $.get(shared.backend, {r: 'aux'}, populate, 'json');
  }
}


/*==========================================================================*
  === MAIN =================================================================
 *==========================================================================*/

$(document).ready(function() 
{
  //--- fill in "logged as" display
  
  $.get(shared.backend, populate_login_info);

  //--- handle sidebar menu highlights
  
  $('div.menu').on('click', function() {
    $('div.selected').removeClass('selected');
    $(this).addClass('selected');
  });

  //--- switch list

  $('div#swlist').on('click', function() {
    var switchList = new modSwitchList(shared);
  });
  
  //--- search tool
  
  $('div#srctool').on('click', function() {
    var searchTool = new modSearchTool(shared);
  });
  
  //--- add patches
  
  $('div#addpatch').on('click', function() {
    var addPatchesForm = new modAddPatchesForm(shared);
  });
  
  //--- default page
  
  $('div#swlist').trigger('click');
  
});


})(); //======================================================================
