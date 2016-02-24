(function() { //==============================================================


/*--------------------------------------------------------------------------*
  Initialization (FIXME: Dust really needs to be global?) 
 *--------------------------------------------------------------------------*/

dust = require('dustjs-helpers');

var
  backend = 'spam-backend.cgi',
  auxdata;


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
  $.get(backend, arg, function(data) {
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
      }
      auxdata = aux;
    }
  };

  //--- load data from backend or use cached values
  
  if(auxdata != undefined) {
    populate(auxdata);
  } else {  
    $.get(backend, {r: 'aux'}, populate, 'json');
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
      $.get(backend, form, function(search) {

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


/*--------------------------------------------------------------------------*
  Table renumbering; we are supposing that all INPUT, BUTTON and SPAN
  elements have two numerals in their names/ids that are renumbered.
 *--------------------------------------------------------------------------*/

function renumber_table(evt)
{
  // iterate over table rows
  $(this).find('tbody').find('tr').each(function() {
    var 
      row = $(this).index(),
      row_s = row + '';

    if(row_s.length < 2) { row_s = '0' + row_s; }
   
    // iterate over TD elements in a row
    $(this).find('td').each(function() {
      var 
        col = $(this).index(),
        name,
        jq_el;
      col_s = col;
      if(col == 0) {
        $(this).text(row+1 + '.');
      } else {
        $(this).find('input,button,span').each(function() {
          name = $(this).attr('name');
          if(!name) { name = $(this).attr('id'); }
          if(name) {
            name = name.replace(/\d\d$/, row_s);
            $(this).attr('name', name);
          }
        });
      }
    });
  });
  evt.stopPropagation();
}


/*--------------------------------------------------------------------------*
  Remove single row from table.
 *--------------------------------------------------------------------------*/

function remove_table_row(evt) 
{
  var jq_table_rows = $('table.addpatch tbody').find('tr');
  if(jq_table_rows.length > 1) {
    $(this).remove();
    $('table.addpatch').trigger('renumber');
  }
  evt.preventDefault();
}


/*--------------------------------------------------------------------------*
  Add table row.
 *--------------------------------------------------------------------------*/

function add_table_row(evt) {
  var jq_table_rows = $('table.addpatch tbody').find('tr');
  if(jq_table_rows.length < 100) {
    var new_row = $(this).clone(true);
    new_row.find('input').val(null);
    var v = $(this).find('input[name^="addp_sw"]').val();
    var n = $(this).find('input[name^="addp_sw"]').attr('name');
    $(new_row).find('input[name='+n+']').val(v);
    new_row.find('td').each(function(idx, el) {
      var v = $(el).children('input').val();
      if(!v) { $(el).removeClass(); }
    });
    $(this).after(new_row).trigger('renumber');
  }
}
      
      
/*--------------------------------------------------------------------------*
  Add Patches
 *--------------------------------------------------------------------------*/

function add_patches() 
{
  dust.render('addpatch', {}, function(err, out) {

    // blur event mis-fire prevention; we set this variable to 1 anywhere
    // where we don't want to have blur events finishing after an event
    // being handled
    
    var prevent_blur = 0;

    // render content
          
    $('#content').html(out);
    $('select[name=addp_site]')
    .each(populate_select_sites);
      
  //--- table rows renumbering -----------------------------------------------

    $('table.addpatch').on('renumber', renumber_table);
      
  //--- removing rows --------------------------------------------------------
  
      $('table.addpatch tbody').find('tr')
      .on('remove', remove_table_row)
      
  //--- adding rows ----------------------------------------------------------

      .on('add', add_table_row);
      
  //--- bind events to +/- buttons -------------------------------------------
            
      $('table.addpatch tbody')
      .find('button[name^="addp_dl"')
      .on('click', function(evt) {
        $(this).trigger('remove');
        evt.preventDefault();
        evt.stopPropagation();
      });

      $('table.addpatch tbody')
      .find('button[name^="addp_ad"')
      .on('click', function(evt) {
        $(this).trigger('add');
        evt.preventDefault();
        evt.stopPropagation();
      });

  //--- blur events ----------------------------------------------------------
  
  // Blur events trigger validation/normalization of user-entered form values
  // Note: blur/focus events do not bubble up
  
      if(0) { /* DISABLED HANDLING OF BLUR EVENTS */
      $('input').on('blur', function(evt) {

        var 
          _this = this,
          arg = {
            r: 'addpnorm',
            type: $(this).attr('name').substr(5, 2),
            val: $(this).val()
          };

  //--- non-empty value, try to validate
  
        if(arg.val) {

          // normalization of cp/outlet fields
          if(arg.type == 'cp' || arg.type == 'ou') {
            $.get(backend, arg, function(data) {
              if(prevent_blur) { prevent_blur = 0; return; }
              if('result' in data) {
                $(_this).val(data.result);
              }
            });
            $(_this).parent().addClass('valid'); 
          } else 

          // switch/port verification
          if(arg.type == 'sw' || arg.type == 'pt') {
            var 
              jq_tr = $(this).parents('tr'),              // parent TR
              jq_sw = jq_tr.find('input[name^=addp_sw]'), // "switch" INPUT
              jq_pt = jq_tr.find('input[name^=addp_pt]'), // "port" INPUT
              sw    = jq_sw.val(),                        // "switch" value
              pt    = jq_pt.val(),                        // "port" value
              si    = $('select[name=addp_site]').val();  // "site" value
              
            console.log("FORM: site = '%s', switch = '%s', port = '%s'", si, sw, pt);
            $.get(backend, { r:'swport', site:si, host:sw, portname:pt }, function(data) {
              if(prevent_blur) { prevent_blur = 0; return; }
              if(data.status = 'ok') {
                console.log("BACK: switch = '%s', port = '%s'", data.result.host, data.result.portname);
                
                if(data.result.host) {
                  jq_sw.val(data.result.host);
                  if(data.result.exists.host) {
                    jq_sw.parent().removeClass().addClass('valid'); 
                  }
                } else {
                  if(sw) {
                    jq_sw.parent().removeClass().addClass('invalid');
                  } else {
                    jq_sw.parent().removeClass();
                  }
                }
                
                if(data.result.portname) {
                  jq_pt.val(data.result.portname);
                  if('exists' in data.result && data.result.exists.portname) {
                    jq_pt.parent().removeClass().addClass('valid');
                  }
                } else {
                  if(pt) {
                    jq_pt.parent().removeClass().addClass('invalid');
                  } else {
                    jq_pt.parent().removeClass();
                  }
                }
              }
            });
          }
        }
  
  //--- empty value is never valid
          
        else {
          $(_this).parent().removeClass('valid');
        }
      });
      } /* END OF BLUR EVENTS */

  //--- switching between cp/outlet and cp modes -----------------------------
  
  // hide or show 'outlet' column; this needs to be implemented since
  // some sites use two-level patching hierarchy (switch-cp-outlet), while
  // most of them use direct switch-outlet patching
  
      $('table.addpatch').on('addpmode', function(evt, mode) {
        if($(this).attr('data-mode') != mode) {
          $('table.addpatch').find('th,td').each(function() {
            var tag = $(this).prop('tagName'),
                idx = $(this).index();
            if(
              tag == 'TD' && idx == 4 ||
              tag == 'TH' && idx == 3
            ) { 
              if(mode == 'cponly') {  $(this).hide(); }
              else if(mode == 'outlet') { $(this).show(); }
            }
          })
          $(this).attr('data-mode', mode);
        }
      });
      
  //--- change handler for site selector
  
  // on switching the site we inquire the backend whether the new site
  // uses cp-outlet or cp-only mode and switch the form accordingly
  // through the 'addpmode' event defined above
      
      $('select[name=addp_site]').on('change', function(evt) {
        var site = $(this).val();
        console.log("site changed to %s", site);
        if(site) { localStorage.setItem('addpatchsite', site); }
        $.get(backend, { r : 'usecp', site: $(this).val() }, function(data) {
          if(data.status == 'ok') {
            if(data.result) {
              $('table.addpatch').trigger('addpmode', ['outlet']);
            } else {
              $('table.addpatch').trigger('addpmode', ['cponly']);
            }
          }
        });
      }).trigger('change');
     
  //--- row status message
  
  // handler that will change status message for a given row; we expect
  // that the event.target is either TR or child of TR
  
      $('table.addpatch').on('statmsg', function(evt, mesg, cl) {
        var target = evt.target,
            tag = $(target).prop('tagName');
        // event.target is not a TR, try to find TR in the chain of ancestors
        if(tag != 'TR') {
          target = $(evt.target).parents('tr').eq(0);
        }
        // do nothing if we don't have valid row
        if(!target) { return; }
        // find the status message TD
        var el = $(target).children('td').last().children('span'),
            tx = el.html();
        if(tx && mesg) {
          el.removeClass().html(tx + '<br>' + mesg);
        } else {
          el.removeClass().html(mesg);
        }
        if(cl) { el.addClass(cl); }      
      });
      
  //--- form reset
  
      $('table.addpatch').on('reset', function(evt) {
        $(this).children('tbody').find('tr').not(':first').trigger('remove');
        $(this).children('tbody').find('tr').find('input').val(undefined);
        $(this).children('tbody').find('td').removeClass();
        $('div#addp_mesg p').addClass('nodisp');
        $('table.addpatch tbody tr').trigger('statmsg', '');
        evt.stopPropagation();
      });

  //--- reset button
  
      $('button[name=addp_reset]').on('click', function(evt) {
        prevent_blur = 1;
        $('table.addpatch').trigger('reset');
        evt.preventDefault();
      });

  //--- submit button

  // NOTE: currently simplified version without any validation
    
      $('button[name=addp_submit]').on('click', function(evt) {
        
        // object to hold the POST data for the backend query
        var arg = { 
          r: 'addpatch',
          site: $('select[name=addp_site]').val()
        };
        console.log("submit: addp_site = %s", arg.site);
        
        // move form data into arg object
        $('table.addpatch').find('input').each(function(idx) {
          arg[$(this).attr('name')] = $(this).val();
        });

        // backend query
        $.post(backend, arg, function(data) {
          
          // display feedback data from backend; this is run even when the
          // actual database transaction fails; the data from backends are:
          //  * normalized field values
          //  * validation result
          //  * error messages for validation failures

          $('table.addpatch tbody').find('tr').each(function() {
            $(this).trigger('statmsg', '');
          });
          if('result' in data) {
            data.result.forEach(function(val, idx) {
              for(var field in val) {
                var jq_input = $('input[name=' + val[field].name + ']');
                jq_input.val(val[field].value);
                if(val[field].err) {
                  jq_input.trigger('statmsg', val[field].err);
                }
                if(!val[field].valid) {
                  jq_input.parent().addClass('invalid');
                } else {
                  jq_input.parent().removeClass('invalid');
                }
              }
            });
          }
          
          // general error message

          $('#addp_mesg p').addClass('nodisp');
          if('status' in data && data.status == 'error') {
            $('#addp_mesg p.error span').text(data.errmsg.toLowerCase());
            $('#addp_mesg p.error').removeClass('nodisp');
          }
          
          // success
          
          if('status' in data && data.status == 'ok') {
            $('table.addpatch').trigger('reset');
            $('#addp_mesg p.success').removeClass('nodisp');
          }
          
        }, 'json');
        
        evt.preventDefault();
      });
  
    });
}


/*==========================================================================*
  === MAIN =================================================================
 *==========================================================================*/

$(document).ready(function() 
{
  //--- fill in "logged as" display
  
  $.get(backend, populate_login_info);

  //--- handle sidebar menu highlights
  
  $('div.menu').on('click', function() {
    $('div.selected').removeClass('selected');
    $(this).addClass('selected');
  });

  //--- switch list
    
  $('div#swlist div').addClass('timer');
  $.get(backend, {r: 'swlist'}, function(data) {
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
  
  $('div#addpatch').on('click', add_patches);
});


})(); //======================================================================
