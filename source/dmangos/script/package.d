/**
 * The scripting framework (docs/SCRIPTING.md): what a script imports.
 *
 * ---
 * import dmangos.script;
 *
 * @creature("npc_example")
 * struct Example
 * {
 *     enum Step : ubyte { shout }
 *     Schedule!Step steps;
 *
 *     void on(ref CreatureContext me, const ref EnteredCombat e)
 *     {
 *         steps.every(Step.shout, 10.seconds);
 *     }
 *
 *     void on(ref CreatureContext me, Step step)
 *     {
 *         me.say(-1000001);
 *     }
 * }
 * ---
 */
module dmangos.script;

public import core.time : msecs, seconds;
public import dmangos.script.api;
public import dmangos.script.escort : Escort;
public import dmangos.script.registry : creature, gameObject, instance;
public import dmangos.script.schedule : Schedule;
public import dmangos.script.state : transient;
