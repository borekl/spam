// SWITCH PORTS ACTIVITY MONITOR - PPMAP CLIENT-SIDE SCRIPT
// 2009-2010 Borek Lupomesky <borek.lupomesky@vodafone.com>

/*
TO DO BEFORE THIS CAN REPLACE LEGACY PPMAP
""""""""""""""""""""""""""""""""""""""""""
- printing current user / group -- DONE
- textual list of outlets -- DONE
- ability to switch between visual map and textual list of outlets -- DONE
- automatic fallback to textual list when browser does not support <canvas>
*/


/*--- global variables --------------------------------------------------*/

var cell_w = 49;          // map cell width
var cell_h = 14;          // map cell height
var coordsMap = [];
var ppcols, pprows;       // ppmap columns and rows
var ctx;                  // canvas context
var canText = 1;          // existence of Canvas Text API
var dispMode = 'normal';  // display mode for ppmap


/*--- color type definitions --------------------------------------------*/

var ctypes = [];
ctypes["trm"] = [255,100,200]; ctypes["end"] = [100,100,200];
ctypes["srv"] = [200,200,100]; ctypes["int"] = [200,50,50];
ctypes["swi"] = [100,200,100]; ctypes["act"] = [200,100,0];
ctypes["cpo"] = [75,75,150];   ctypes["non"] = [0,0,0];

ctypes["swiACT"] = [100,255,100];
ctypes["swiDWN"] = [255,100,100];
ctypes["swiSHU"] = [100,100,100];
ctypes["swiERR"] = [255,255,0];
ctypes["swiUNK"] = [50,100,50];

/*-----------------------------------------------------------------------*
  Function for generating colour codes for outlets.
 *-----------------------------------------------------------------------*/

function color_code(type, mute) {
  var flag = 1;
  if(ctypes[type] === undefined) { flag = 0; }
  if(mute == null) { mute = 1; }
  if(flag == 1) {
    var r = "rgb(";
    var c1 = ctypes[type][0] / mute;
    var c2 = ctypes[type][1] / mute;
    var c3 = ctypes[type][2] / mute;
    r += Math.floor(c1).toString() + ",";
    r += Math.floor(c2).toString() + ",";
    r += Math.floor(c3).toString() + ")";
  } else {
    var c = 50 / mute;
    r = Math.floor(c).toString()
    r = "rgb(" + r + "," + r + "," + r + ")";
  }
  return r;
}


/*-----------------------------------------------------------------------*
  This function processes data and does the following: 1) draws
  canvas for graphical representation; 2) outputs text for textual
  representation; 3) creates coordinates base in-memory representation
  (coordsMap).

  Arguments: jdata ... data retrieved from backed (object)
             search .. filter string
             canvas .. draw canvas?
             map ..... create coords map?
 *-----------------------------------------------------------------------*/

function process_data(jdata, search, canvas, map)
{
  var selectCount = 0;
  var totalCount = 0;
  var re = new RegExp(search, "i");
  var span = 'a';

  //--- clear coordsMap if not filtering

  if(map) { coordsMap.length = 0; }

  //--- iterate

  for(k in jdata.data) {
    var col = jdata.data[k][0];
    var row = jdata.data[k][1];
    var pos = jdata.data[k][2];
    var label = jdata.data[k][3];
    var type = jdata.data[k][4];
    var sw_host = jdata.data[k][5];
    var sw_oper = jdata.data[k][9];
    var sw_admin = jdata.data[k][8];
    var sw_errdis = jdata.data[k][10];
    totalCount++;

    //--- create coordsMap

    if(map) {
      if(coordsMap[col] == undefined) { coordsMap[col] = []; }
      if(coordsMap[col][row] == undefined) { coordsMap[col][row] = []; }
      if(coordsMap[col][row][pos] == undefined) { coordsMap[col][row][pos] = []; }
      coordsMap[col][row][pos] = label;
    }

    //--- do canvas drawing

    if(ctx && canvas) {
      if(dispMode == "normal") {
        ctx.fillStyle = color_code(type, 1);
      } else if(dispMode == "switch") {
        if(type != "swi") { type = "non"; }
        else if(!sw_host) { type = "swiUNK"; }
        else if(sw_oper == 1) { type = "swiACT"; }
        else if(sw_oper == 0 && sw_admin == 1) { type = "swiDWN"; }
        else if(sw_oper == 0 && sw_admin == 0 && sw_host) { type = "swiSHU"; }
        else if(sw_oper == 0 && sw_errdis == 1) { type = "swiERR"; }
        ctx.fillStyle = color_code(type, 1);
      }
    }
    if(search) {
      if(label.search(re) != -1) {
        if(ctx && canvas) { ctx.fillStyle = color_code(type, 1); }
        $('pre').append('<SPAN CLASS="' + span + '">' + String.fromCharCode(col+64)+' '+row+' '+pos+'  '+label+"</SPAN>\n");
        if(span == 'a') { span = 'b'; } else { span = 'a'; }
        selectCount++;
      } else {
        var mf = 3; // "mute factor"
        if(dispMode == "switch") { mf = 6; }
        if(ctx && canvas) { ctx.fillStyle = color_code(type, mf); }
      }
    } else {
      selectCount++;
    }
    if(ctx && canvas) {
       ctx.fillRect((col - 1) * cell_w + (pos - 1) * (cell_w/7), (row - 1) * cell_h, 
                   cell_w/7, cell_h);
    }
  }
  return [totalCount, selectCount];
}


/*-----------------------------------------------------------------------*
  Initialize canvas.
 *-----------------------------------------------------------------------*/

function init_canvas()
{
  if(!ctx) { return; }
  var canvas_w = $('canvas').attr('width');
  var canvas_h = $('canvas').attr('height');
  ctx.save();
  ctx.clearRect(0,0,canvas_w,canvas_h);
  ctx.translate(26.5, 0.5);
}


/*-----------------------------------------------------------------------*
  This function draws canvas grid and tick labels.
 *-----------------------------------------------------------------------*/

function draw_canvas()
{
  if(!ctx) { return; }

  //--- basic canvas init
  
  // draw basic grid

  ctx.strokeStyle = "rgb(128,128,128)";
  ctx.fillStyle = "black";
  if(canText) { ctx.font = "bold 12pt sans-serif"; }
  for(var i = 0; i <= ppcols; i++) {
    ctx.beginPath();
    ctx.moveTo(i * cell_w, 0);
    ctx.lineTo(i * cell_w, cell_h * pprows);
    ctx.closePath();
    ctx.stroke();
    if(i != ppcols) {
      if(canText) {
        var ch = String.fromCharCode(i+65);
        var w = ctx.measureText(ch).width;
        ctx.fillText(ch, i * cell_w + cell_w/2 - w/2, cell_h * pprows + 20 );
      }
    }
  }
  if(canText) {
    ctx.font = "10pt sans-serif";
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
  }
  for(var i = 0; i <= pprows; i++) {
    ctx.beginPath();
    ctx.moveTo(0, i * cell_h);
    ctx.lineTo(cell_w * ppcols , i * cell_h);
    ctx.closePath();
    ctx.stroke();
    if(i != pprows) {
      if(canText) {
        ctx.fillText((i+1).toString(), -6, i * cell_h + cell_h/2 + 1);
      }
    }
  }
  ctx.restore();
}


/*-----------------------------------------------------------------------*
  Function to calculate (column, row, position) from mouse coordinates.
 *-----------------------------------------------------------------------*/

function get_pos(x,y) {
  var pos_col, pos_row, pos_pos;

  row = Math.floor(y / cell_h) + 1;
  col = Math.floor(x / cell_w) + 1;
  pos = Math.floor((x % cell_w) / (cell_w/7)) + 1;

  if(row < 1 || row > pprows || col < 1 || col > ppcols) {
    return [-1,-1,-1];
  }

  return [col, row, pos];
}


/*-----------------------------------------------------------------------*
  Handler for canvas mousemove event.
 *-----------------------------------------------------------------------*/

function canvas_mousemove(e) {
  var canv = $('#ppmap').get(0);
  var y = e.pageY - canv.offsetTop;
  var x = e.pageX - canv.offsetLeft - 26;
  var pos = get_pos(x,y);
  if(pos[0] == -1) {
    $('span#coords').text('');
    $('span#label').text('');
  } else try {
    if(coordsMap[pos[0]][pos[1]][pos[2]]) {
      $('span#coords').text(String.fromCharCode(pos[0] + 64) + pos[1] + ' ' + pos[2]);
      $('span#label').text(coordsMap[pos[0]][pos[1]][pos[2]]);
    } else {
      $('span#coords').text(String.fromCharCode(pos[0] + 64) + pos[1] + ' ' + pos[2]);
      $('span#label').text('');
    }
  } catch(err) {
    $('span#coords').text(String.fromCharCode(pos[0] + 64) + pos[1] + ' ' + pos[2]);
    $('span#label').text('');
  }
}


/*-----------------------------------------------------------------------*
  M A I N
 *-----------------------------------------------------------------------*/

$(document).ready(function()
{
  //--- tabs

  var $tabs = $('#tabs').tabs();
  var selected = $tabs.tabs('option', 'selected');
  $('#tabs').bind('tabsselect', function(event, ui) {
    selected = ui.index ;
    return true;
  });

  //--- site cookie

  var cookie = $.cookie('spam_ppmap2_site');
  if(cookie) { $('#site').val(cookie); }

  //--- canvas initialization

  var canvas = document.getElementById('ppmap');
  ctx = canvas.getContext('2d');
  try {
    ctx.fillText('.', 0,0);
  } catch(err) {
    canText = 0;
  }

  //--- [site] combobox change handler

  $('#site').change(function () {
    var csite = $('#site').val();
    if(cookie != csite) {
      $.cookie('spam_ppmap2_site', csite, { path : '/spam/', expires : 999 });
      cookie = csite;
    }
    $('#search').val('');
    $('#status').css("display","block");
    $.get('spam-backend.cgi', { q: "ppmap", id: csite }, function(jdata) {
      // FIXME: check return status in jdatata.status (ok, error)
      ppcols = jdata.col_max;
      pprows = jdata.row_max;
      $('#status').css("display","none");
      var search = $('#search').val();
      init_canvas();
      var ret = process_data(jdata, search, true, true);
      draw_canvas();
      $('#count').text(ret[0] + '/' + ret[1]);

      //--- submit handler

      $('#submit').click(function () { 
        var search = $('#search').val();
        var ret;
        $('pre').empty();
        if(!search) { $('pre').append('No outlet filter'); }
        init_canvas();
        ret = process_data(jdata, search, true, false);
        draw_canvas();
        $('#count').text(ret[1] + '/' + ret[0]);
      });

      //--- reset handler

      $('#reset').click(function () {
         $('#search').val('');
      });

      //--- mouseout handler

      $('#ppmap').mouseout(function() {
        $('span#coords').text('');
        $('span#label').text('');
      });

      //--- mousemove handler

      $('#ppmap').mousemove(function(e) { canvas_mousemove(e); });

      //--- "display mode" radio button change handler

      $('input[name="dispmode"]').change(function() {
        dispMode = $(this).val();
        var search = $('#search').val();
        init_canvas();
        var ret = process_data(jdata, search, true, true);
        draw_canvas();
        $('#count').text(ret[1] + '/' + ret[0]);
      });
    });
  });

  //--- on page load, execute change handler to get dynamic stuff drawn

  $('#site').change();
});

