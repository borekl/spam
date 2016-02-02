/*=========================================================================*
  SPAM "Add Patch" Form JavaScript helper
 *=========================================================================*/


/*-----------------------------------------------------------------------*
  Function to format integer into fixed length string by filling in zeros
  in the front.
 *-----------------------------------------------------------------------*/

function format_int(i, n)
{
  var s = i.toString();
  while(s.length < n) { s = '0' + s; }
  return s;
}


/*-----------------------------------------------------------------------*
 *-----------------------------------------------------------------------*/

function form_reset()
{
  var jq_row1 = $('table').children('tbody').children().eq(1);
  jq_row1.nextAll('tr').remove();
  jq_row1.children('td').children('input').val('');
  $('pre#summary').remove();
  $('big').remove();
  $(this).trigger('renumber');
  return false;
}

/*-----------------------------------------------------------------------*
 *-----------------------------------------------------------------------*/

function row_remove()
{
  /*--- get some information ---*/
  var jq_srtable = $(this).parents('table');        // parent TABLE element
  var jq_tr = $(this).parent().parent();            // parent TR element
  var jq_select = jq_tr.find('select[name=site]');  // is there "site" SELECT element
  
  /*--- remove current row ---*/
  $(this).parent().parent().remove();
  
  /*--- if the first row doesn't have "site" SELECT, put it back ---*/
  var jq_row1 = $('table').children('tbody').children('tr:not(:first-child)').eq(0);
  var jq_td1 = jq_row1.children().eq(1);
  if(!jq_td1.children('select[name=site]').length) {
    jq_td1.append(jq_select);
  }
  
  /*--- trigger renumbering and finish ---*/
  jq_srtable.trigger('renumber');
  return false;
}


/*-----------------------------------------------------------------------*
 *-----------------------------------------------------------------------*/

function row_add()
{
  /*--- create clone of entire row where [add] was clicked on ---*/
  var jq_tr_curr = $(this).parent().parent();
  var jq_tr_new = jq_tr_curr.clone(true);
  jq_tr_new.find('select[name=site]').remove(); // "site" field is only on the first row
  
  /*--- append new row ---*/
  jq_tr_curr.after(jq_tr_new);

  /*--- empty nocopy fields ---*/
  jq_tr_new.find('input[name^=port]').val('');
  jq_tr_new.find('input[name^=cp]').val('');
  jq_tr_new.find('input[name^=outlet]').val('');
    
  /*--- trigger table renumbering and finish ---*/
  jq_tr_curr.parents('table').trigger('renumber');
  return false;
}


/*-----------------------------------------------------------------------*
 *-----------------------------------------------------------------------*/

function table_renumber()
{
  var jq_rows = $('table').children('tbody').children('tr:not(:first-child)');
  var rows = jq_rows.length;
  var jq_td, jq_button, jq_button_new;

  jq_rows.each(function (idx) {
    jq_td = jq_rows.eq(idx).children('td').last();
    jq_button = jq_td.children('button');
    if(rows > 1) {
      if(jq_button.length == 1) {
        jq_button_new = jq_button.eq(0).clone();
        jq_button_new.attr('name','remove00').text('−');
        jq_button_new.click(row_remove);
        jq_button.after(jq_button_new);
      }
    } else if(rows == 1) {
      if(jq_button.length == 2) {
        jq_button.eq(1).remove();
      }
    }
    $(this).children('td').eq(0).html((idx + 1) + '.')
      .nextAll().children('select,button,input').each(function() {
        var name = $(this).attr('name');
        if(name != 'site') {
          name = name.substr(0, name.length-2) + format_int(idx, 2);
          $(this).attr('name', name);
        }
      });
  });
  $('input[name=rows]').val(rows);
}


/*-----------------------------------------------------------------------*
 *-----------------------------------------------------------------------*/

function site_change()
{
  var site = $(this).val();
  var jq_table = $('table');
  
  $.get('spam-backend-old.cgi', { q: "usecp", site: site }, function(x) {
    var col4 = jq_table.find('th').eq(4).text();
    if(col4 == 'cp' && x.data == 0) {
      // remove table column 'cp'
      jq_table.find('tr').find('td:eq(4),th:eq(4)').remove();
    } else if(col4 == 'outlet' && x.data == 1) {
      // add table column 'cp'
      var jq_tr = jq_table.find('tr');
      jq_tr.find('th:eq(4)').before("<th>cp</th>");
      jq_tr.find('td:eq(4)').each(function() {
        var rowno = $(this).parent().find('td:eq(0)').text();
        var rowno2 = rowno.match(/[0-9]+/g);
        rowno2[0]--;
        if(rowno2.length < 2) {
          rowno2[0] = '0' + rowno2[0];
        }
        $(this).after('<td><input name="outlet'+rowno2[0]+'" size="16" maxlength="16" type="text"></td>');
      });
    }
  });
}



/*-----------------------------------------------------------------------*
  MAIN
 *-----------------------------------------------------------------------*/

$(document).ready(function ()
{
  $('button[name=add00]').click(row_add);
  $('button[name=reset]').click(form_reset);
  $('select[name=site]').change(site_change);
  $('table').on('renumber', table_renumber);
});
