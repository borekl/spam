/*==========================================================================*
  SWITCH PORTS ACTIVITY MONITOR / Port Info

  This module implements editable elements. Clicking on an element changes
  it into an INPUT with type=text, allows user to enter value and then
  either cancels it by losing focus or calls an callback after Enter being
  pressed. The widget is configured with the second argument to the
  constructor.

  el: target element; this should be something that gives sensible text()
  size: INPUT's size attribute
  save: callback that performs the save; must return jQuery promise object
  spinclass: when the callback is running, editable will put up IMG for
    spinner and this property determines the class the IMG element gets.
  errclass: CSS class for the error message
 *==========================================================================*/


module.exports = editable;

function editable(shared, arg) {

/*--------------------------------------------------------------------------*
  Module variables.
 *--------------------------------------------------------------------------*/

var
  jq_el = $(arg.el),        // the target element
  jq_el_saved,              // the target element off-DOM storage
  jq_el_parent,             // target element's parent
  saved_txt,                // saved text content of the target element
  empty,                    // is the target element logically empty
  jq_input,                 // new INPUT element
  jq_input_span;            // SPAN wrapping the INPUT



/*--------------------------------------------------------------------------*
  Save edited text.
 *--------------------------------------------------------------------------*/

function editableSave(evt)
{
  var promise, text, jq_spin;

  //--- get the INPUT value

  text = jq_input.val();

  //--- put up spinner

  jq_input_span.remove();
  jq_spin = $('<img src="assets/spin-black.svgz">');
  if('spinclass' in arg) {
    jq_spin.addClass(arg.spinclass);
  }
  jq_el_parent.append(jq_spin);

  //--- invoke the callback

  promise = arg.save(text);

  //--- success

  promise.done(function() {
    jq_el_parent.find('img').remove();
    if(text == '') {
      jq_el_saved.text('N/A').addClass('na');
    } else {
      jq_el_saved.text(text).removeClass('na');
    }
    jq_el_parent.append(jq_el_saved);
  });

  //--- failure

  promise.fail(function(msg) {
    jq_el_parent.find('img').remove();
    // error message dismissable by click
    var jq_err = $('<span></span>')
      .addClass(arg.errclass)
      .text(msg)
      .appendTo(jq_el_parent)
      .on('click', function() {
        $(this).remove();
        jq_el_parent.append(jq_el_saved);
      });
  });
}


/*--------------------------------------------------------------------------*
  Editing event handler. To be called as focusout/keyup handler.
 *--------------------------------------------------------------------------*/

function editableEvent(evt)
{
  if(evt.type == 'keyup') {
    if(evt.keyCode == 13) {
      jq_input.off(evt.type);
      evt.preventDefault();
      editableSave(evt);
      return;
    } else if(evt.keyCode != 27) {
      return true;
    }
  }
  jq_input.off(evt.type);
  jq_input_span.replaceWith(jq_el_saved);
}


/*--------------------------------------------------------------------------*
  Initialization.
 *--------------------------------------------------------------------------*/

//--- unmatched target element, do nothing

if(jq_el.length == 0) { return; }

//--- save target element's parent

jq_el_parent = jq_el.parent();

//--- is target element empty

saved_txt = jq_el.hasClass('na') ? '' : jq_el.text();

//--- create the INPUT wrapped in SPAN

jq_input_span = $('<span class="modwire"><input></span>');
jq_input = jq_input_span.children();
jq_input.attr('type', 'text').val(saved_txt);
if('size' in arg) { jq_input.attr('size', arg.size); }

//--- save the original element

jq_el_saved = jq_el.detach();
jq_el_parent.append(jq_input_span);

//--- focus the INPUT

jq_input.focus()
  .get(0).setSelectionRange(saved_txt.length, saved_txt.length);

//--- on losing focus (= user clicked outside of the INPUT) or pressing ESC
//--- we cancel the edit entirely

jq_input.on('focusout', editableEvent);
jq_input.on('keyup', editableEvent);


/*--- end of module --------------------------------------------------------*/

}
