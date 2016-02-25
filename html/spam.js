(function() { //==============================================================


/*--------------------------------------------------------------------------*
  Initialization (FIXME: Dust really needs to be global?) 
 *--------------------------------------------------------------------------*/

dust = require('dustjs-helpers');

var
  auxdata,
  modAddPatchesForm = require('./addpatches.js'),
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
  Render port list
 *--------------------------------------------------------------------------*/

function port_list(el)
{
  var 
    host = $(this).text(),
    arg = { r : "search", host: host };
  
  $('div#swlist div').addClass('timer');
  $.get(shared.backend, arg, function(data) {
    dust.render('switch', data, function(err, out) {
      $('#content').html(out);
      $('div#swlist div').removeClass('timer');
    });    
  });
}


/*--------------------------------------------------------------------------*
  Render switch list from previously loaded data.
 *--------------------------------------------------------------------------*/

function render_switch_list(data)
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
      render_switch_list(data);
    });
    $('table#swlist tbody td.host span.lnk').on('click', port_list);
  });
}


/*--------------------------------------------------------------------------*
  Reset the Search Tool
 *--------------------------------------------------------------------------*/

function search_reset()
{
  $('div#result').empty();
  $('input').val('');
  $('select[name=site]').prop('selectedIndex', 0);
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


/*--------------------------------------------------------------------------*
  Context helper for filtering switch list.
 *--------------------------------------------------------------------------*/

function ctx_helper_filterhost(chunk, context, bodies, params)
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
  Search Tool
 *--------------------------------------------------------------------------*/

function search_tool() 
{
  dust.render('search', {}, function(err, out) {
    $('#content').html(out);
    $('select[name=site]').each(populate_select_sites);
    $('button#reset').click('on', search_reset);
    $('button#submit').click('on', function() {
  
  //--- put form fields into an object 'form'
 
      var form = new Object;
      form.r = 'search';
      $('input,select').each(function() {
        var name = $(this).attr('name'),
            val = $(this).val();
        if((name == 'site' && val != 'any') || (name != 'site' && val)) {
          form[name] = val;
        }
      });
  
  //--- submit the form data to backend and get results back
  
      $('div#srctool div').addClass('timer');
      $.get(shared.backend, form, function(search) {

  //--- replace form field values with normalized values supplied by the
  //--- backend, using ' as the first character in the form field inhibits
  //--- the normalization
  
        for(var field in search.params.normalized) {
          if(search.params.raw[field].substr(0,1) != "'") {
            $('input[name=' + field  + ']').val(search.params.normalized[field]);
          }
        }

  //--- display the result
  
        if(search.status == 'error') {
          alert('Search Fail!');
        } else {
          dust.render('srcres', search, function(err, out) {
            $('div#result').html(out);
          });
        }
        $('div#srctool div').removeClass('timer');
      });
    });
  });
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
    
  $('div#swlist div').addClass('timer');
  $.get(shared.backend, {r: 'swlist'}, function(data) {
    var grp = localStorage.getItem('swlistgrp');
    data.grp = grp ? grp : 'all';
    data.filterhost = ctx_helper_filterhost;
    $('div#swlist').on('click', function() { 
      render_switch_list(data); 
      $('div#swlist div').removeClass('timer');
    }).click();
  });
  
  //--- search tool
  
  $('div#srctool').on('click', search_tool);
  
  //--- add patches
  
  $('div#addpatch').on('click', function() {
    var addPatchesForm = new modAddPatchesForm(shared);
  });
});


})(); //======================================================================
