// Stop words for base query extraction — covers all app-supported languages.
// Applied in aggregate (all languages at once) so language detection is not needed.
const StopWords = (function() {
    var lists = {
        en: [
            'what','how','why','when','where','who','which','is','are','was','were',
            'do','does','did','can','could','should','would','will','shall','may','might','must',
            'tell','me','explain','describe','find','search','show','give','list',
            'a','an','the','of','in','on','at','to','for','with','about','and','or','but',
            'my','your','his','her','their','our','its',
            'i','you','he','she','they','we','it','this','that','these','those',
            'be','been','being','have','has','had',
            'from','by','up','out','if','then','than','so','as','into','through',
            'before','after','above','below','between','each','more','most',
            'other','some','such','no','not','only','same','too','very','just',
            'because','while','also','get','make','like','know','want','need'
        ],
        de: [
            'was','ist','sind','war','waren','bin','bist','sei','wäre','wären',
            'hat','haben','hatte','hatten','wird','werden','würde','würden',
            'soll','sollen','sollte','kann','können','konnte','muss','müssen','musste',
            'darf','dürfen','mag','möchte','möchten',
            'der','die','das','dem','den','des','ein','eine','einen','einem','einer','eines',
            'mein','meine','meinen','meiner','meinem','dein','deine','sein','seine',
            'ihr','ihre','ihren','ihrer','ihrem','unser','euer',
            'ich','du','er','sie','es','wir','euch','sich','mich','dich','uns','ihnen',
            'und','oder','aber','wenn','weil','da','dass','ob',
            'wie','wo','wann','wer','welch','welche','welcher','welches','welchen','welchem',
            'nach','für','mit','von','zu','an','auf','aus','bei','durch','gegen',
            'ohne','über','unter','vor','zwischen','um','bis','ab','seit',
            'nicht','kein','keine','keinen','keinem','keiner',
            'auch','noch','schon','doch','mal','ja','nein','bitte','sehr','viel',
            'geht','kaufen','empfehlen','finden','suchen','geben','zeigen',
            'in','im','am','beim','zum','zur','ins','ans'
        ],
        fr: [
            'que','qui','quoi','où','quand','comment','pourquoi','quel','quelle','quels','quelles',
            'est','sont','était','étaient','sera','seront','serait','être',
            'ai','as','a','avons','avez','ont','avoir','avait','avaient',
            'le','la','les','un','une','des','du','de','en','à','au','aux',
            'par','pour','avec','sur','dans','sans','sous','entre','vers','chez',
            'je','tu','il','elle','nous','vous','ils','elles','me','te','se','lui','leur','y',
            'mon','ma','mes','ton','ta','tes','son','sa','ses','notre','votre',
            'mais','ou','et','donc','or','ni','car','si',
            'bien','aussi','tout','plus','très','ne','pas','non','oui',
            'ce','cet','cette','ces','celui','celle','ceux','celles',
            'trouver','acheter','chercher','recommander','expliquer','montrer'
        ],
        es: [
            'qué','cómo','por','cuándo','dónde','quién','cuál','cuáles',
            'es','son','era','fue','ser','estar','estoy','estás','está','estamos','están',
            'tengo','tienes','tiene','tenemos','tienen','tener',
            'hay','haber','he','has','ha','hemos','han',
            'el','la','los','las','un','una','unos','unas',
            'de','en','a','al','del','por','para','con','sin','sobre',
            'entre','hacia','desde','hasta','durante','según',
            'yo','tú','él','ella','nosotros','vosotros','ellos','ellas',
            'me','te','se','le','nos','mi','mis','tu','tus','su','sus','nuestro','nuestra',
            'pero','sino','y','o','ni','si','porque','cuando','donde','como',
            'más','muy','también','ya','no','todo','mucho','poco','bien',
            'comprar','buscar','recomendar','encontrar','quiero','necesito','debo','puedo'
        ],
        vi: [
            'gì','là','ở','đâu','khi','nào','ai','có','không','được','cho',
            'với','từ','trong','ngoài','trên','dưới','và','hay','hoặc','nhưng',
            'vì','để','của','về','theo','bởi','như','thì','mà','rằng',
            'cũng','đã','sẽ','đang','bị','tôi','bạn','anh','chị','em','họ','chúng',
            'này','đó','kia','đây','các','những','nhiều','ít','rất','lắm',
            'nên','phải','cần','muốn','hỏi','mua','tìm','gợi','ý','giúp'
        ]
    };

    // Flatten all languages into one Set for fast lookup
    var _all = new Set();
    Object.keys(lists).forEach(function(lang) {
        lists[lang].forEach(function(w) { _all.add(w.toLowerCase()); });
    });

    return {
        all: _all,

        // Strip stop words from a query string and return cleaned keywords
        extractKeywords: function(text) {
            return text
                .replace(/[,?!'"«»„""'']/g, ' ')
                .replace(/–|—/g, ' ')
                .split(/\s+/)
                .map(function(w) { return w.replace(/[.,;:!?]+$/, ''); })
                .filter(function(w) {
                    var lw = w.toLowerCase();
                    return lw.length > 1 && !_all.has(lw);
                })
                .join(' ')
                .trim();
        }
    };
})();
