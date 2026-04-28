package main

import (
	"fmt"
	"math/rand"
	"net/http"
	"strings"
	"time"
)

var articles = map[string]string{
	"/": `<!DOCTYPE html>
<html>
<head><title>Wikipedia - The Free Encyclopedia</title></head>
<body>
<h1>Wikipedia</h1>
<p>Wikipedia is a free, multilingual, multilingual Internet encyclopedia. It has more than 55 million articles in over 300 languages.</p>
<h2>Main Topics</h2>
<ul>
<li><a href="/science">Science</a>
<ul>
<li><a href="/science/physics">Physics</a></li>
<li><a href="/science/biology">Biology</a></li>
<li><a href="/science/chemistry">Chemistry</a></li>
</ul></li>
<li><a href="/history">History</a>
<ul>
<li><a href="/history/ancient">Ancient History</a></li>
<li><a href="/history/modern">Modern History</a></li>
</ul></li>
<li><a href="/geography">Geography</a>
<ul>
<li><a href="/geography/continents">Continents</a></li>
<li><a href="/geography/countries">Countries</a></li>
</ul></li>
<li><a href="/technology">Technology</a>
<ul>
<li><a href="/technology/computing">Computing</a></li>
<li><a href="/technology/internet">Internet</a></li>
</ul></li>
<li><a href="/arts">Arts</a>
<ul>
<li><a href="/arts/literature">Literature</a></li>
<li><a href="/arts/music">Music</a></li>
<li><a href="/arts/painting">Painting</a></li>
</ul></li>
<li><a href="/philosophy">Philosophy</a>
<ul>
<li><a href="/philosophy/ancient">Ancient Philosophy</a></li>
<li><a href="/philosophy/modern">Modern Philosophy</a></li>
</ul></li>
</ul>
<p><a href="/about">About Wikipedia</a></p>
</body>
</html>`,

	"/about": `<!DOCTYPE html>
<html>
<head><title>About Wikipedia</title></head>
<body>
<h1>About Wikipedia</h1>
<p>Wikipedia is a free, multilingual Internet encyclopedia. It is operated by the Wikimedia Foundation, a non-profit organization.</p>
<p>Wikipedia was launched on January 15, 2001, by Jimmy Wales and Larry Sanger. It has grown to become one of the most visited websites on the Internet.</p>
<h2>Core Principles</h2>
<ul>
<li>Neutral point of view</li>
<li>Verifiability</li>
<li>No original research</li>
</ul>
<h2>Statistics</h2>
<p>Wikipedia has more than 55 million articles in more than 300 languages. The English Wikipedia alone contains over 6 million articles.</p>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/science": `<!DOCTYPE html>
<html>
<head><title>Science</title></head>
<body>
<h1>Science</h1>
<p>Science is a systematic enterprise that builds and organizes knowledge in the form of testable explanations and predictions about the universe.</p>
<p>Modern science is typically divided into three major branches: natural sciences (physics, chemistry, biology), social sciences (psychology, sociology, economics), and formal sciences (mathematics, logic).</p>
<h2>Branches</h2>
<ul>
<li><a href="/science/physics">Physics</a> - Study of matter, energy, and their interactions</li>
<li><a href="/science/biology">Biology</a> - Study of life and living organisms</li>
<li><a href="/science/chemistry">Chemistry</a> - Study of substances and their transformations</li>
</ul>
<h2>Scientific Method</h2>
<p>The scientific method is a process for experimentation that is used to observe, discover, and explain natural phenomena. It involves making observations, forming hypotheses, conducting experiments, and analyzing results.</p>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/science/physics": `<!DOCTYPE html>
<html>
<head><title>Physics</title></head>
<body>
<h1>Physics</h1>
<p>Physics is the scientific study of matter, its fundamental constituents, motion and behavior through space and time, and the related entities of energy and force.</p>
<p>Physics is one of the most fundamental scientific disciplines. It is one of the oldest academic disciplines, dating back to ancient Greece.</p>
<h2>History</h2>
<p>Over much of the past two millennia, physics was part of natural philosophy. During the Scientific Revolution in the 17th century, physics emerged as a separate field. Major developments include Newton's laws of motion, Maxwell's electromagnetism, quantum mechanics, and Einstein's theory of relativity.</p>
<h2>Core Theories</h2>
<ul>
<li><strong>Classical mechanics</strong> - Describes motion of everyday objects (Newton's laws)</li>
<li><strong>Electromagnetism</strong> - Describes electricity, magnetism, and light (Maxwell's equations)</li>
<li><strong>Thermodynamics</strong> - Describes heat and energy transfer</li>
<li><strong>Quantum mechanics</strong> - Describes behavior of atomic and subatomic particles</li>
<li><strong>Relativity</strong> - Describes gravity and high-speed motion (Einstein)</li>
</ul>
<h2>Branches</h2>
<ul>
<li>Mechanics</li>
<li>Electromagnetism</li>
<li>Quantum mechanics</li>
<li>Thermodynamics</li>
<li>Nuclear physics</li>
<li>Astrophysics</li>
</ul>
<p><a href="/science">Return to Science</a></p>
</body>
</html>`,

	"/science/biology": `<!DOCTYPE html>
<html>
<head><title>Biology</title></head>
<body>
<h1>Biology</h1>
<p>Biology is the scientific study of life and living organisms, including their physical structure, chemical processes, molecular interactions, physiological mechanisms, development, and evolution.</p>
<p>Biology encompasses various fields such as molecular biology, genetics, ecology, and evolutionary biology. It seeks to understand the structure, function, growth, origin, evolution, and distribution of living organisms.</p>
<h2>Fundamental Themes</h2>
<ul>
<li><strong>The cell</strong> - The basic unit of life</li>
<li><strong>Genes</strong> - Units of heredity</li>
<li><strong>Evolution</strong> - Process of species change over time</li>
<li><strong>Energy transformation</strong> - Metabolism and photosynthesis</li>
<li><strong>Homeostasis</strong> - Maintenance of internal balance</li>
</ul>
<h2>Branches</h2>
<ul>
<li>Botany - Study of plants</li>
<li>Zoology - Study of animals</li>
<li>Microbiology - Study of microorganisms</li>
<li>Genetics - Study of heredity</li>
<li>Ecology - Study of ecosystems</li>
</ul>
<p>Modern biology is grounded in Darwin's theory of evolution by natural selection and the molecular understanding of genes encoded in DNA.</p>
<p><a href="/science">Return to Science</a></p>
</body>
</html>`,

	"/science/chemistry": `<!DOCTYPE html>
<html>
<head><title>Chemistry</title></head>
<body>
<h1>Chemistry</h1>
<p>Chemistry is the scientific discipline involved with elements and compounds composed of atoms, molecules, and ions. It studies their composition, structure, properties, behavior, and the changes they undergo during chemical reactions.</p>
<p>Chemistry is often called "the central science" because it connects physics and biology, explaining phenomena ranging from plant growth to medication effectiveness.</p>
<h2>History</h2>
<p>Chemistry evolved from alchemy, with roots in ancient Egypt and Mesopotamia. Modern chemistry was established by Antoine Lavoisier, who introduced the scientific method and the principle of conservation of mass.</p>
<h2>Branches</h2>
<ul>
<li><strong>Organic chemistry</strong> - Study of carbon compounds</li>
<li><strong>Inorganic chemistry</strong> - Study of non-organic compounds</li>
<li><strong>Physical chemistry</strong> - Study of chemical energetics and kinetics</li>
<li><strong>Analytical chemistry</strong> - Analysis of chemical composition</li>
<li><strong>Biochemistry</strong> - Chemistry of living organisms</li>
</ul>
<h2>Periodic Table</h2>
<p>The periodic table organizes all known chemical elements by their atomic number and electron configuration. It contains 118 known elements, organized into periods and groups.</p>
<p><a href="/science">Return to Science</a></p>
</body>
</html>`,

	"/history": `<!DOCTYPE html>
<html>
<head><title>History</title></head>
<body>
<h1>History</h1>
<p>History is the study of the past, especially of human societies and events. It examines what happened in previous eras and seeks to understand the causes and consequences of historical events.</p>
<p>History provides identity, helps us understand the present, and teaches valuable lessons from the past. It is one of the humanities disciplines.</p>
<h2>Periods</h2>
<ul>
<li><a href="/history/ancient">Ancient History</a> - From earliest times to around 500 CE</li>
<li><a href="/history/modern">Modern History</a> - From around 1500 to present</li>
</ul>
<h2>Importance of History</h2>
<p>History helps us understand the present by learning from the past. It provides cultural heritage, national identity, and valuable lessons about human society and governance.</p>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/history/ancient": `<!DOCTYPE html>
<html>
<head><title>Ancient History</title></head>
<body>
<h1>Ancient History</h1>
<p>Ancient history is the period of human history from the beginning of recorded history (around 3000 BCE) to the fall of the Western Roman Empire (around 500 CE). It covers the emergence of civilization through classical antiquity.</p>
<h2>Early Civilizations</h2>
<ul>
<li><strong>Mesopotamia</strong> - The "Cradle of Civilization" in modern Iraq</li>
<li><strong>Ancient Egypt</strong> - Known for pyramids and pharaohs</li>
<li><strong>Indus Valley Civilization</strong> - Urban planning in South Asia</li>
<li><strong>Ancient China</strong> - Yellow River civilization</li>
</ul>
<h2>Classical Antiquity</h2>
<ul>
<li><strong>Ancient Greece</strong> - Birthplace of democracy and Western philosophy</li>
<li><strong>Roman Empire</strong> - Law, engineering, and vast territories</li>
<li><strong>Persian Empire</strong> - Achaemenid dynasty</li>
</ul>
<h2>Key Achievements</h2>
<ul>
<li>Construction of the Egyptian pyramids</li>
<li>Invention of writing systems</li>
<li>Development of democracy in Athens</li>
<li>Creation of Roman law and roads</li>
</ul>
<p><a href="/history">Return to History</a></p>
</body>
</html>`,

	"/history/modern": `<!DOCTYPE html>
<html>
<head><title>Modern History</title></head>
<body>
<h1>Modern History</h1>
<p>Modern history encompasses the period from around 1450 to the present. It is typically divided into the Early Modern period (1450-1750), the Modern era (1750-1945), and Contemporary history (1945-present).</p>
<h2>Major Eras</h2>
<h3>Early Modern (1450-1750)</h3>
<ul>
<li>Renaissance - Cultural and artistic rebirth in Europe</li>
<li>Age of Discovery - European exploration of the world</li>
<li>Scientific Revolution - Birth of modern science</li>
</ul>
<h3>Modern Era (1750-1945)</h3>
<ul>
<li>Industrial Revolution - Transformation to industrial society</li>
<li>French Revolution - Rise of democracy</li>
<li>World War I and II - Global conflicts</li>
</ul>
<h3>Contemporary (1945-present)</h3>
<ul>
<li>Cold War - US-Soviet rivalry</li>
<li>Digital Revolution - Rise of computers and internet</li>
<li>Globalization - Interconnected world</li>
</ul>
<p><a href="/history">Return to History</a></p>
</body>
</html>`,

	"/geography": `<!DOCTYPE html>
<html>
<head><title>Geography</title></head>
<body>
<h1>Geography</h1>
<p>Geography is the field of science devoted to the study of the lands, features, inhabitants, and phenomena of Earth. It seeks to understand Earth and its human and natural complexities.</p>
<p>Geography has been called "a bridge between natural science and social science disciplines." The core concepts include space, place, time, and scale.</p>
<h2>Branches</h2>
<ul>
<li><strong>Physical Geography</strong> - Natural features of Earth</li>
<li><strong>Human Geography</strong> - Human activity and societies</li>
<li><strong>Technical Geography</strong> - Mapping and GIS</li>
</ul>
<h2>Sub-disciplines</h2>
<ul>
<li><a href="/geography/continents">Continents</a></li>
<li><a href="/geography/countries">Countries</a></li>
<li>Climatology</li>
<li>Geomorphology</li>
<li>Biogeography</li>
</ul>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/geography/continents": `<!DOCTYPE html>
<html>
<head><title>Continent</title></head>
<body>
<h1>Continent</h1>
<p>A continent is any of several large terrestrial geographical regions. Continents are generally identified by convention rather than strict criteria.</p>
<h2>The Seven Continents</h2>
<ol>
<li><strong>Asia</strong> - Largest and most populous (44.5 million km²)</li>
<li><strong>Africa</strong> - Second most populous (30.2 million km²)</li>
<li><strong>North America</strong> - 24.7 million km²</li>
<li><strong>South America</strong> - 17.8 million km²</li>
<li><strong>Antarctica</strong> - Ice-covered (14 million km²)</li>
<li><strong>Europe</strong> - Smallest by land area (10.2 million km²)</li>
<li><strong>Australia/Oceania</strong> - Smallest by population (8.5 million km²)</li>
</ol>
<h2>Geological Definition</h2>
<p>In geology, continents are defined by high elevation, varied rock types, and thicker crust than oceanic crust. The theory of continental drift explains how today's continents formed from the supercontinent Pangaea.</p>
<h2>Continental Drift</h2>
<p>Using the theory of plate tectonics, scientists understand that Earth's continents were once joined as a single landmass called Pangaea and have slowly moved to their current positions over millions of years.</p>
<p><a href="/geography">Return to Geography</a></p>
</body>
</html>`,

	"/geography/countries": `<!DOCTYPE html>
<html>
<head><title>Country</title></head>
<body>
<h1>Country</h1>
<p>A country is an area of land with defined borders and a government that operates as a sovereign state. Countries are the primary political divisions of the world.</p>
<h2>Number of Countries</h2>
<p>There is no universal agreement on the number of countries due to disputes over sovereignty. The United Nations recognizes 193 member states. Some sources count more than 300 political entities.</p>
<h2>Largest Countries by Area</h2>
<ol>
<li>Russia - 17.1 million km²</li>
<li>Canada - 9.98 million km²</li>
<li>United States - 9.83 million km²</li>
<li>China - 9.6 million km²</li>
<li>Brazil - 8.5 million km²</li>
<li>Australia - 7.7 million km²</li>
</ol>
<h2>Most Populous Countries</h2>
<ol>
<li>China - 1.4 billion</li>
<li>India - 1.4 billion</li>
<li>United States - 331 million</li>
<li>Indonesia - 273 million</li>
<li>Pakistan - 220 million</li>
<li>Brazil - 212 million</li>
</ol>
<h2>Classification</h2>
<p>Countries may be classified as developed or developing based on economic indicators, human development index, and other metrics.</p>
<p><a href="/geography">Return to Geography</a></p>
</body>
</html>`,

	"/technology": `<!DOCTYPE html>
<html>
<head><title>Technology</title></head>
<body>
<h1>Technology</h1>
<p>Technology is the application of conceptual knowledge to achieve practical goals. It includes both tangible tools like machines and intangible ones like software.</p>
<p>Technology contributes to economic development, improves human prosperity, and drives social change. However, it can also have negative impacts like pollution and technological unemployment.</p>
<h2>Fields</h2>
<ul>
<li><a href="/technology/computing">Computing</a> - Computers and software</li>
<li><a href="/technology/internet">Internet</a> - Global network connectivity</li>
<li>Biotechnology</li>
<li>Nanotechnology</li>
<li>Artificial Intelligence</li>
</ul>
<h2>Key Developments</h2>
<ol>
<li>Stone tools - Earliest known technology</li>
<li>Fire control - Enabled cooking and warmth</li>
<li>The wheel - Enabled transportation</li>
<li>Printing press - Enabled mass communication</li>
<li>Internet - Connected the world</li>
</ol>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/technology/computing": `<!DOCTYPE html>
<html>
<head><title>Computing</title></head>
<body>
<h1>Computing</h1>
<p>Computing is any goal-oriented activity requiring, benefiting from, or creating computing machinery. It encompasses scientific, engineering, and technological aspects of computer use.</p>
<p>The field includes major disciplines such as computer engineering, computer science, cybersecurity, data science, and software engineering.</p>
<h2>History of Computing</h2>
<ul>
<li><strong>Ancient</strong> - Abacus, mechanical calculators</li>
<li><strong>1800s</strong> - Charles Babbage's Analytical Engine</li>
<li><strong>1940s</strong> - First electronic computers (ENIAC)</li>
<li><strong>1950s</strong> - Transistors replace vacuum tubes</li>
<li><strong>1970s</strong> - Personal computers</li>
<li><strong>1990s</strong> - Internet becomes mainstream</li>
<li><strong>2000s</strong> - Mobile computing</li>
</ul>
<h2>Programming Languages</h2>
<ul>
<li>Python - Popular for data science and AI</li>
<li>JavaScript - Web development</li>
<li>Java - Enterprise applications</li>
<li>C/C++ - Systems programming</li>
<li>Go - Modern systems programming</li>
</ul>
<h2>Key Figures</h2>
<ul>
<li>Ada Lovelace - First programmer</li>
<li>Alan Turing - Father of computer science</li>
<li>Bill Gates - Microsoft founder</li>
<li>Tim Berners-Lee - World Wide Web inventor</li>
</ul>
<p><a href="/technology">Return to Technology</a></p>
</body>
</html>`,

	"/technology/internet": `<!DOCTYPE html>
<html>
<head><title>Internet</title></head>
<body>
<h1>Internet</h1>
<p>The Internet is a global network of computers that communicate using standardized protocols. It is the backbone of modern digital communication and the World Wide Web.</p>
<p>The Internet enables email, web browsing, streaming media, online gaming, and countless other services that connect billions of people worldwide.</p>
<h2>Key Protocols</h2>
<ul>
<li><strong>TCP/IP</strong> - Core internet protocol suite</li>
<li><strong>HTTP</strong> - Web traffic protocol</li>
<li><strong>HTTPS</strong> - Secure web traffic</li>
<li><strong>SMTP</strong> - Email transfer</li>
<li><strong>FTP</strong> - File transfer</li>
<li><strong>DNS</strong> - Domain name system</li>
</ul>
<h2>History</h2>
<ul>
<li><strong>1969</strong> - ARPANET created</li>
<li><strong>1983</strong> - TCP/IP becomes standard</li>
<li><strong>1989</strong> - World Wide Web invented</li>
<li><strong>1993</strong> - Mosaic web browser released</li>
<li><strong>1995</strong> - Internet opened to commercial use</li>
</ul>
<h2>World Wide Web</h2>
<p>The World Wide Web was invented by Tim Berners-Lee in 1989. It uses HTTP to transmit HTML pages over the Internet.</p>
<p><a href="/technology">Return to Technology</a></p>
</body>
</html>`,

	"/arts": `<!DOCTYPE html>
<html>
<head><title>Art</title></head>
<body>
<h1>Arts</h1>
<p>The arts are a broad range of human activities involving the creation or performance of visual, auditory, or performed artifacts. They express imaginative or technical skill beyond everyday practical skills.</p>
<p>The arts include painting, sculpture, architecture, music, dance, theater, film, and literature. They serve as means of cultural expression and communication.</p>
<h2>Categories</h2>
<ul>
<li><strong>Visual arts</strong> - Painting, sculpture, photography</li>
<li><strong>Performing arts</strong> - Theater, dance, music</li>
<li><strong>Literary arts</strong> - Poetry, prose, drama</li>
<li><a href="/arts/literature">Literature</a></li>
<li><a href="/arts/music">Music</a></li>
<li><a href="/arts/painting">Painting</a></li>
</ul>
<h2>Functions of Art</h2>
<ul>
<li>Expression of emotions and ideas</li>
<li>Cultural preservation</li>
<li>Entertainment</li>
<li>Social commentary</li>
<li>Aesthetic appreciation</li>
</ul>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/arts/literature": `<!DOCTYPE html>
<html>
<head><title>Literature</title></head>
<body>
<h1>Literature</h1>
<p>Literature is any collection of written works. In its narrower sense, it is an art form including novels, plays, and poetry, serving as a method of recording, preserving, and transmitting knowledge and entertainment.</p>
<p>Literature includes both print and digital writing. In recent centuries, it has expanded to include oral traditions as well.</p>
<h2>Genres</h2>
<ul>
<li><strong>Fiction</strong> - Made-up stories</li>
<li><strong>Poetry</strong> - Expressive verse</li>
<li><strong>Drama</strong> - Written for performance</li>
<li><strong>Non-fiction</strong> - Factual writing</li>
<li><strong>Essays</strong> - Short prose pieces</li>
</ul>
<h2>Major Literary Works</h2>
<ul>
<li>The Iliad - Ancient Greek epic</li>
<li>Don Quixote - Spanish novel</li>
<li>War and Peace - Russian novel</li>
<li>Harry Potter - Modern phenomenon</li>
</ul>
<h2>Literary Movements</h2>
<ul>
<li>Romanticism</li>
<li>Realism</li>
<li>Modernism</li>
<li>Postmodernism</li>
</ul>
<p>The earliest literature consists of oral traditions dating back thousands of years, preserved through storytelling and later written records.</p>
<p><a href="/arts">Return to Arts</a></p>
</body>
</html>`,

	"/arts/music": `<!DOCTYPE html>
<html>
<head><title>Music</title></head>
<body>
<h1>Music</h1>
<p>Music is an art form consisting of sounds organized in time. It is one of the universal cultural aspects of all human societies, generally recognized as a cultural universal.</p>
<p>Music can be performed solo or in groups, with voices, instruments, or both. It serves purposes ranging from ceremonial to entertainment.</p>
<h2>Elements</h2>
<ul>
<li><strong>Rhythm</strong> - Pattern of sounds and silences</li>
<li><strong>Melody</strong> - Organized musical notes</li>
<li><strong>Harmony</strong> - Simultaneous sounds</li>
<li><strong>Tempo</strong> - Speed of performance</li>
<li><strong>Dynamics</strong> - Volume variations</li>
<li><strong>Tone</strong> - Quality of sound</li>
</ul>
<h2>Major Genres</h2>
<ul>
<li>Classical music</li>
<li>Jazz</li>
<li>Rock and Roll</li>
<li>Pop music</li>
<li>Electronic music</li>
<li>Folk music</li>
<li>Country music</li>
</ul>
<h2>Instrument Families</h2>
<ul>
<li>Strings - Violin, guitar, cello</li>
<li>Winds - Flute, clarinet, saxophone</li>
<li>Brasses - Trumpet, trombone, tuba</li>
<li>Percussion - Drums, cymbals</li>
<li>Keyboard - Piano, organ</li>
</ul>
<p><a href="/arts">Return to Arts</a></p>
</body>
</html>`,

	"/arts/painting": `<!DOCTYPE html>
<html>
<head><title>Painting</title></head>
<body>
<h1>Painting</h1>
<p>Painting is a visual art characterized by applying paint, pigment, color, or other medium to a solid surface. It is one of the oldest forms of human artistic expression.</p>
<p>The oldest known paintings are more than 40,000-60,000 years old, found in caves in Indonesia and France.</p>
<h2>Techniques</h2>
<ul>
<li><strong>Oil painting</strong> - Using oil-based paints</li>
<li><strong>Watercolor</strong> - Water-soluble pigments</li>
<li><strong>Acrylic</strong> - Synthetic fast-drying paint</li>
<li><strong>Pastel</strong> - Dry pigment sticks</li>
<li><strong>Tempera</strong> - Egg-based medium</li>
<li><strong>Fresco</strong> - Paint on wet plaster</li>
</ul>
<h2>Art Movements</h2>
<ul>
<li>Renaissance - 14th-17th century</li>
<li>Baroque - 17th-18th century</li>
<li>Impressionism - 19th century</li>
<li>Post-Impressionism - Late 19th century</li>
<li>Cubism - Early 20th century</li>
<li>Abstract art - 20th century</li>
</ul>
<h2>Master Artists</h2>
<ul>
<li>Leonardo da Vinci - Mona Lisa</li>
<li>Michelangelo - Sistine Chapel</li>
<li>Vincent van Gogh - Starry Night</li>
<li>Pablo Picasso - Guernica</li>
<li>Claude Monet - Water Lilies</li>
</ul>
<p>The invention of photography in the 19th century had a major impact on painting, leading to new art movements that explored different ways of seeing reality.</p>
<p><a href="/arts">Return to Arts</a></p>
</body>
</html>`,

	"/philosophy": `<!DOCTYPE html>
<html>
<head><title>Philosophy</title></head>
<body>
<h1>Philosophy</h1>
<p>Philosophy (from Greek "philosophia" meaning "love of wisdom") is a systematic study of fundamental questions about existence, knowledge, mind, reason, language, and value.</p>
<p>Philosophy uses methods including conceptual analysis, thought experiments, and critical questioning to examine these questions.</p>
<h2>Major Branches</h2>
<ul>
<li><strong>Metaphysics</strong> - Study of reality and existence</li>
<li><strong>Epistemology</strong> - Study of knowledge</li>
<li><strong>Logic</strong> - Study of reason and argument</li>
<li><strong>Ethics</strong> - Study of morality and good life</li>
<li><strong>Aesthetics</strong> - Study of beauty and art</li>
</ul>
<h2>Traditions</h2>
<ul>
<li><a href="/philosophy/ancient">Ancient Philosophy</a> - Greek and Eastern traditions</li>
<li><a href="/philosophy/modern">Modern Philosophy</a> - 17th-20th century</li>
<li>Eastern philosophy - Chinese, Indian traditions</li>
</ul>
<h2>Methods</h2>
<ul>
<li>Conceptual analysis</li>
<li>Thought experiments</li>
<li>Logical argumentation</li>
<li>Critical questioning</li>
</ul>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,

	"/philosophy/ancient": `<!DOCTYPE html>
<html>
<head><title>Ancient Greek Philosophy</title></head>
<body>
<h1>Ancient Greek Philosophy</h1>
<p>Ancient Greek philosophy arose in the 6th century BCE in the Greek colonies of Ionia. It dealt with cosmology, epistemology, ethics, and metaphysics.</p>
<p>Greek philosophy profoundly influenced Western culture, establishing foundations for subsequent Western thought through the works of Socrates, Plato, and Aristotle.</p>
<h2>Pre-Socratic Philosophers</h2>
<ul>
<li><strong>Thales</strong> - Water as the fundamental substance</li>
<li><strong>Heraclitus</strong> - Everything is in flux</li>
<li><strong>Parmenides</strong> - Change is impossible</li>
<li><strong>Democritus</strong> - Atomic theory of matter</li>
</ul>
<h2>Classical Period</h2>
<ul>
<li><strong>Socrates</strong> - Questioning method, ethics</li>
<li><strong>Plato</strong> - Theory of forms, idealism</li>
<li><strong>Aristotle</strong> - Logic, empiricism, ethics</li>
</ul>
<h2>Schools</h2>
<ul>
<li>Stoicism - Living in accordance with nature</li>
<li>Epicureanism - Pursuit of pleasure (moderation)</li>
<li>Cynicism - Virtue is the only good</li>
<li>Skepticism - Questioning all knowledge</li>
</ul>
<h2>Legacy</h2>
<p>Plato's theory of forms and Aristotle's empirical approach form foundations for subsequent Western philosophy and science.</p>
<p><a href="/philosophy">Return to Philosophy</a></p>
</body>
</html>`,

	"/philosophy/modern": `<!DOCTYPE html>
<html>
<head><title>Modern Philosophy</title></head>
<body>
<h1>Modern Philosophy</h1>
<p>Modern philosophy developed from the 17th to early 20th centuries, associated with modernity. It includes Rationalism, Empiricism, German Idealism, and analytic philosophy.</p>
<h2>Rationalists</h2>
<ul>
<li><strong>Descartes</strong> - Cogito ergo sum (I think, therefore I am)</li>
<li><strong>Spinoza</strong> - Rationalist ethics</li>
<li><strong>Leibniz</strong> - Best possible world</li>
</ul>
<h2>Empiricists</h2>
<ul>
<li><strong>Locke</strong> - Tabula rasa (blank slate)</li>
<li><strong>Berkeley</strong> - Esse est percipi (to be is to be perceived)</li>
<li><strong>Hume</strong> - Skepticism about causation</li>
</ul>
<h2>German Idealism</h2>
<ul>
<li><strong>Kant</strong> - Critical philosophy, synthetic a priori</li>
<li><strong>Hegel</strong> - Dialectical method</li>
</ul>
<h2>19th-20th Century</h2>
<ul>
<li>Existentialism - Sartre, Camus</li>
<li>Phenomenology - Husserl, Heidegger</li>
<li>Pragmatism - James, Dewey</li>
<li>Analytic philosophy - Russell, Wittgenstein</li>
</ul>
<h2>Key Concepts</h2>
<ul>
<li>Social contract</li>
<li>Natural rights</li>
<li>Categorical imperative</li>
<li>Will to power</li>
<li>Language games</li>
</ul>
<p><a href="/philosophy">Return to Philosophy</a></p>
</body>
</html>`,

	"/search": `<!DOCTYPE html>
<html>
<head><title>Search - Wikipedia</title></head>
<body>
<h1>Search Wikipedia</h1>
<form action="/search" method="get">
<input type="text" name="q" placeholder="Search Wikipedia"/>
<button type="submit">Search</button>
</form>
<p><a href="/">Return to Main Page</a></p>
</body>
</html>`,
}

var visited = make(map[string]int)

func init() {
	rand.Seed(time.Now().UnixNano())
}

func randomString(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}

func wikiHandler(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	if path == "" {
		path = "/"
	}

	visited[path]++
	time.Sleep(time.Duration(rand.Intn(500)) * time.Millisecond)

	content, ok := articles[path]
	if !ok {
		http.Error(w, "404 Not Found", http.StatusNotFound)
		return
	}

	q := r.URL.Query().Get("q")
	if q != "" && path == "/search" {
		count := rand.Intn(100) + 1
		content = strings.Replace(content, "<h1>Search Wikipedia</h1>", "<h1>Search - "+q+"</h1>", 1)
		content = strings.Replace(content, "</form>", "</form>\n<p>Found approximately "+fmt.Sprintf("%d", count)+" results for \""+q+"\"</p>", 1)
	}

	requestID := randomString(16)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("X-Request-ID", requestID)
	w.Header().Set("X-Response-Time", fmt.Sprintf("%d", rand.Intn(1000))+"ms")
	w.Write([]byte(content))
}

func statsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"pages": %d, "visits": %d}`, len(articles), len(visited))
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", wikiHandler)
	mux.HandleFunc("/_stats", statsHandler)

	fmt.Printf("Wikipedia mock running on http://localhost:8880\n")
	fmt.Printf("Pages: %d\n", len(articles))
	http.ListenAndServe(":8880", mux)
}