# General
- using native interactions as much as possible
- smooth swipe gestures used for navigation and liquid glass
- few components that are reused for visual consistency 
- design uses a blue accent defined in ...

# Home Screen
top to bottom:
- current date top left, liquid glass gear icon top right goes to **Settings Screen**
<remove calendar row>
- infinite scroll list of notes in reverse chronological order, each note:
  - shows subtle date, time left aligned, duration right aligned and title below
  - swipe left on a note to show trash icon that can be tapped to show a confirm before deletion
  - tap note to go to **Note Screen**
- a primary "record" button floating in the bottom right goes to **Record Screen**
- a glass "Review" button floating bottom float goes to **Review Screen**

# Note Screen
top to bottom:
<remove back button>
- location name left algined, date right aligned format: Day Name, Month Day, [year if it's not current year]
- note title center aligned
- note play control: play/payse button, waveform, time left
<remove ai summary>
- note transcription with a subtle right aligned model name that was used to transcribe the audio
- location name and apple maps pin of the location (non interactive). tapping the apple maps opens the google maps at that location
